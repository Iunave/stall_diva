#include <cstdlib>
#include <cstdint>
#include <cerrno>
#include <csignal>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <vector>
#include <cstring>
#include <string>
#include <array>
#include <fmt/format.h>
#include <map>
#include <unordered_map>
#include <span>

#define LOG(message, ...) fmt::print("{}: " message "\n", timestamp_formatted() __VA_OPT__(,) __VA_ARGS__)

struct http_message_t
{
    std::string data{};

    http_message_t& line(std::string_view in)
    {
        data.append(fmt::format("{}\r\n", in));
        return *this;
    }
};

struct http_request_t
{
    std::string buffer;
    std::string_view request_type;
    std::string_view request_path;
    std::string_view http_version;
    std::map<std::string, std::string> headers;
};

struct client_t
{
    pthread_t listener = 0;
    int socket = 0;
    sockaddr_in address = {};
    bool logged_in = false;
};

enum handler_id_t : uint16_t
{
    pasture = 0b00,
    stable_in = 0b01,
    stable_out = 0b10
};

std::string handler_id2string(handler_id_t handler_id)
{
    switch(handler_id)
    {
        case handler_id_t::pasture: return "pasture";
        case handler_id_t::stable_in: return "stable_in";
        case handler_id_t::stable_out: return "stable_out";
        default: return "invalid value";
    }
}

struct __attribute__((packed)) handler_key_t
{
    handler_id_t id;
    uint16_t day;
    uint32_t year;

    constexpr friend auto operator<=>(const handler_key_t& lhs, const handler_key_t& rhs){
        return std::bit_cast<uint64_t>(lhs) <=> std::bit_cast<uint64_t>(rhs);
    }

    std::string to_string() const {
        return fmt::format("id: {}, day: {}, year: {}", handler_id2string(id), day, year);
    }
};

template<>
struct std::hash<handler_key_t>
{
    constexpr size_t operator()(const handler_key_t& in)
    {
        return std::bit_cast<size_t>(in);
    }
};

sig_atomic_t shutdown_server = 0;
int server_socket = 0;

std::vector<client_t> clients{};
pthread_rwlock_t clients_lock{};

std::unordered_map<handler_key_t, std::u16string> handlers{};
pthread_rwlock_t handlers_lock{};

enum class client_message_type_e : uint32_t
{
    login = 0,
    get_handler,
    set_handler,
    max
};

enum class server_message_type_e : uint32_t
{
    login_response = 0,
    sent_handler_name,
    max
};

struct server_message_t
{
    std::vector<uint8_t> message_buffer{};

    server_message_t(server_message_type_e message_type, uint32_t data_size)
    {
        message_buffer.resize(8 + data_size);
        reinterpret_cast<uint32_t&>(message_buffer[0]) = static_cast<uint32_t>(message_type);
        reinterpret_cast<uint32_t&>(message_buffer[4]) = data_size;
    }

    uint8_t* message_data()
    {
        return message_buffer.data() + 8;
    }
};

std::string address2string(sockaddr_in address)
{
    return fmt::format("{}:{}", inet_ntoa(address.sin_addr), address.sin_port);
}

std::string timestamp_formatted()
{
    time_t now;
    time(&now);

    char buffer[100];
    size_t size = strftime(buffer, sizeof(buffer), "%a %Y-%m-%d %H:%M:%S %Z", localtime(&now));

    return std::string{buffer, size};
}

std::string cvt_str16_to_str8(std::u16string_view str)
{
    std::string converted{};
    converted.resize(str.size());

    for(uint64_t index = 0; index < str.size(); ++index)
    {
        converted[index] = str[index] > 128 ? '?' : static_cast<char>(str[index]);
    }

    return converted;
}

void sigterm_handler(int, siginfo_t*, void*)
{
    shutdown_server = 1;
}

void close_server_socket()
{
    if(shutdown(server_socket, SHUT_RDWR) == -1)
    {
        perror("shutdown");
    }

    if(close(server_socket) == -1)
    {
        perror("close");
    }
}

void disconnect_clients()
{
    pthread_rwlock_wrlock(&clients_lock);
    for(const client_t& client : clients)
    {
        if(shutdown(client.socket, SHUT_RDWR) == -1)
        {
            perror("shutdown");
        }
    }
    pthread_rwlock_unlock(&clients_lock);

    while(true)
    {
        pthread_rwlock_rdlock(&clients_lock);
        const uint64_t remaining = clients.size();
        pthread_rwlock_unlock(&clients_lock);

        if(remaining == 0)
        {
            break;
        }

        sched_yield();
    }
}

ssize_t read_http_line(int socket, std::string* line)
{
    while(true)
    {
        char byte;
        ssize_t result = recv(socket, &byte, 1, MSG_WAITALL);
        if(result <= 0)
        {
            return result;
        }

        line->append(1, byte);
        if(line->ends_with("\r\n"))
        {
            return 1;
        }
    }
}

ssize_t read_http_message(int socket, std::string* message)
{
    while(true)
    {
        if(ssize_t result = read_http_line(socket, message); result <= 0)
        {
            return result;
        }

        if(message->ends_with("\r\n\r\n"))
        {
            return 1;
        }
    }
}

ssize_t read_http_request(int socket, http_request_t* request)
{
    ssize_t result = read_http_message(socket, &request->buffer);
    if(result <= 0)
    {
        return result;
    }

    const std::string_view buffer = request->buffer;

    size_t space0 = buffer.find(' ', 0);
    if(space0 == std::string_view::npos)
    {
        return 0;
    }

    size_t space1 = buffer.find(' ', space0 + 1);
    if(space1 == std::string_view::npos)
    {
        return 0;
    }

    size_t newline_pos = buffer.find('\r', space1 + 1);
    if(newline_pos == std::string_view::npos)
    {
        return 0;
    }

    request->request_type = buffer.substr(0, space0);
    request->request_path = buffer.substr(space0 + 1, space1 - space0 - 1);
    request->http_version = buffer.substr(space1 + 1, newline_pos - space1 - 1);

    return 1;
}

ssize_t read_client_message(int socket, uint32_t* buffer_size, void* buffer)
{
    if(buffer == nullptr)
    {
        struct{
            uint32_t type;
            uint32_t size;
        } message_header;

        ssize_t nread = recv(socket, &message_header, sizeof(message_header), MSG_WAITALL | MSG_PEEK);
        if(nread <= 0)
        {
            return nread;
        }

        *buffer_size = sizeof(message_header) + message_header.size;
        return 1;
    }
    else
    {
        return recv(socket, buffer, *buffer_size, MSG_WAITALL);
    }
}

bool find_client(pthread_t listener, client_t* result)
{
    pthread_rwlock_rdlock(&clients_lock);

    for(const client_t& client : clients)
    {
        if(client.listener == listener)
        {
            *result = client;
            pthread_rwlock_unlock(&clients_lock);
            return true;
        }
    }

    pthread_rwlock_unlock(&clients_lock);
    return false;
}

template<typename C>
bool mutate_client(pthread_t listener, C mutator)
{
    pthread_rwlock_wrlock(&clients_lock);

    for(client_t& client : clients)
    {
        if(client.listener == listener)
        {
            mutator(&client);
            pthread_rwlock_unlock(&clients_lock);
            return true;
        }
    }

    pthread_rwlock_unlock(&clients_lock);
    return false;
}

void on_invalid_message(std::span<uint8_t> message, client_t sender)
{
    LOG("recieved invalid message {}. from: {}", reinterpret_cast<const uint32_t&>(message[0]), address2string(sender.address));
}

void on_login_request(std::span<uint8_t> message, client_t sender)
{
    constexpr char password[] = "washington";
    auto entered_password = reinterpret_cast<const char*>(&message[8]);

    server_message_t response{server_message_type_e::login_response, 1};
    *response.message_data() = (std::strcmp(password, entered_password) == 0);

    LOG("login request: {} : {}", address2string(sender.address), *response.message_data() ? "success" : "failure");

    auto set_login_status = [accepted = *response.message_data()](client_t* client){
        client->logged_in = accepted;
    };

    if(mutate_client(sender.listener, set_login_status))
    {
        (void)send(sender.socket, response.message_buffer.data(), response.message_buffer.size(), MSG_NOSIGNAL);
    }
}

void on_get_handler_request(std::span<uint8_t> message, client_t sender)
{
    if(message.size() != 16)
    {
        on_invalid_message(message, sender);
        return;
    }

    auto key = *reinterpret_cast<const handler_key_t*>(&message[8]);

    LOG("{} requested handler {}", address2string(sender.address), key.to_string());

    pthread_rwlock_wrlock(&handlers_lock);
    std::u16string handler_name = handlers[key];
    pthread_rwlock_unlock(&handlers_lock);

    const uint64_t handler_name_bytes = ((handler_name.size() + 1) * 2);

    server_message_t response{server_message_type_e::sent_handler_name, static_cast<uint32_t>(sizeof(handler_key_t) + handler_name_bytes)};
    std::memcpy(response.message_data(), &key, sizeof(handler_key_t));
    std::memcpy(response.message_data() + sizeof(handler_key_t), handler_name.data(), handler_name_bytes);

    (void)send(sender.socket, response.message_buffer.data(), response.message_buffer.size(), MSG_NOSIGNAL);
}

void on_set_handler_request(std::span<uint8_t> message, client_t sender)
{
    if(message.size() <= 16)
    {
        on_invalid_message(message, sender);
        return;
    }

    if(!sender.logged_in)
    {
        LOG("{} tried to set a handler name but is not logged in", address2string(sender.address));
        return;
    }

    auto key = *reinterpret_cast<const handler_key_t*>(&message[8]);
    std::u16string handler_name{reinterpret_cast<const char16_t*>(&message[16]), ((message.size() - 16) / 2) - 1};

    LOG("{}: set handler {} to {}", address2string(sender.address), key.to_string(), cvt_str16_to_str8(handler_name));

    pthread_rwlock_wrlock(&handlers_lock);
    handlers[key] = handler_name;
    pthread_rwlock_unlock(&handlers_lock);

    const uint64_t handler_name_bytes = ((handler_name.size() + 1) * 2);

    server_message_t broadcast_message{server_message_type_e::sent_handler_name, static_cast<uint32_t>(sizeof(handler_key_t) + handler_name_bytes)};
    std::memcpy(broadcast_message.message_data(), &key, sizeof(handler_key_t));
    std::memcpy(broadcast_message.message_data() + sizeof(handler_key_t), handler_name.data(), handler_name_bytes);

    pthread_rwlock_rdlock(&clients_lock);
    for(const client_t& client : clients)
    {
        if(client.listener != sender.listener)
        {
            (void)send(client.socket, broadcast_message.message_buffer.data(), broadcast_message.message_buffer.size(), MSG_NOSIGNAL);
        }
    }
    pthread_rwlock_unlock(&clients_lock);
}

void* client_listener(void*)
{
    auto on_recv_fail = [](ssize_t result, client_t client)
    {
        if(result == 0)
        {
            LOG("client disconnected: {}", address2string(client.address));
        }
        else if(result == -1)
        {
            LOG("client: {}. error on recv: {}", address2string(client.address), strerror(errno));
        }

        mutate_client(pthread_self(), [](client_t* client) //remove client, it has disconnected or errored
        {
            if(close(client->socket) == -1)
            {
                perror("close");
            }

            uint64_t index = std::distance(clients.data(), client);
            clients[index] = clients.back();
            clients.pop_back();
        });

        pthread_exit(nullptr);
    };

    while(true)
    {
        client_t client;
        if(!find_client(pthread_self(), &client))
        {
            pthread_exit(nullptr);
        }

        http_request_t request{};
        ssize_t result = read_http_request(client.socket, &request);
        if(result <= 0)
        {
            on_recv_fail(result, client);
        }

        LOG("{} {} {}", request.request_type, request.request_path, request.http_version);
        fflush(stdout);
/*
        std::string response = "HTTP/1.1 200 OK\r\n"
                               "Server: stall-diva\r\n"
                               "Content-Type: text/html\r\n";

        std::string response_body = "<!DOCTYPE html>\r\n"
                                    "<html lang=\"en-US\">\r\n"
                                    "<head>\r\n"
                                    "<meta charset=\"utf-8\"/>\r\n"
                                    "<meta name=\"viewport\" content=\"width=device-width\"/>\r\n"
                                    "<title>Stall Diva Chemaplanerare</title>\r\n"
                                    "</head>\r\n"
                                    "<body>\r\n"
                                    "<img src=\"https://raw.githubusercontent.com/mdn/beginner-html-site/gh-pages/images/firefox-icon.png\"/>\r\n"
                                    "</body>\r\n"
                                    "</html>";

        response.append(fmt::format("Content-Length: {}\r\n\r\n", response_body.size()));
        response.append(response_body);

        fmt::print("{}", response);
        fflush(stdout);

        (void)send(client.socket, response.data(), response.size(), MSG_NOSIGNAL);
        */
    }
}

int main(int argc, char** argv)
{
    struct sigaction on_terminate{};
    on_terminate.sa_sigaction = &sigterm_handler;

    if(sigaction(SIGTERM, &on_terminate, nullptr) == -1)
    {
        perror("sigaction");
        return EXIT_FAILURE;
    }

    if(argc != 2)
    {
        LOG("port number not supplied");
        return EXIT_FAILURE;
    }

    const uint16_t server_port = std::strtoul(argv[1], nullptr, 10);
    if(errno != 0)
    {
        perror("strtoul");
        return EXIT_FAILURE;
    }

    server_socket = socket(AF_INET, SOCK_STREAM, 0);
    if(server_socket == -1)
    {
        perror("socket");
        return EXIT_FAILURE;
    }

    if(atexit(&close_server_socket) != 0)
    {
        perror("atexit");
        return EXIT_FAILURE;
    }

    const sockaddr_in server_addr{
        .sin_family = AF_INET,
        .sin_port = htons(server_port),
        .sin_addr = {INADDR_ANY}
    };

    if(bind(server_socket, reinterpret_cast<const sockaddr*>(&server_addr), sizeof(server_addr)) == -1)
    {
        perror("bind");
        return EXIT_FAILURE;
    }

    if(listen(server_socket, 8) == -1)
    {
        perror("listen");
        return EXIT_FAILURE;
    }

    LOG("socket initialized and listening");

    pthread_rwlock_init(&clients_lock, nullptr);
    pthread_rwlock_init(&handlers_lock, nullptr);

    pthread_attr_t detached_thread_attr{};
    pthread_attr_init(&detached_thread_attr);
    pthread_attr_setdetachstate(&detached_thread_attr, PTHREAD_CREATE_DETACHED);

    if(atexit(&disconnect_clients) != 0)
    {
        perror("atexit");
        return EXIT_FAILURE;
    }

    while(shutdown_server == 0) //accept clients
    {
        sockaddr_in client_addr{};
        socklen_t client_addr_len = sizeof(client_addr);
        int client_socket = accept(server_socket, reinterpret_cast<sockaddr*>(&client_addr), &client_addr_len);

        if(client_socket == -1)
        {
            perror("accept");
            return EXIT_FAILURE;
        }

        LOG("client connected: {}", address2string(client_addr));

        pthread_rwlock_wrlock(&clients_lock);

        client_t& new_client = clients.emplace_back();
        new_client.address = client_addr;
        new_client.socket = client_socket;
        new_client.logged_in = false;

        int listener_thread_error = pthread_create(&new_client.listener, &detached_thread_attr, &client_listener, nullptr);

        pthread_rwlock_unlock(&clients_lock);

        if(listener_thread_error != 0)
        {
            LOG("error creating listener thread {}", strerror(listener_thread_error));
            return EXIT_FAILURE;
        }
    }

    return EXIT_SUCCESS;
}