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

#define LOG(message, ...) fmt::print("{}: " message "\n", timestamp_formatted() __VA_OPT__(,) __VA_ARGS__)

constexpr uint8_t END_OF_TRANSMISSION_BLOCK = 23;

struct client_t
{
    pthread_t listener = 0;
    int socket = 0;
    sockaddr_in address = {};
    bool logged_in = false;
};

struct handler_key_t
{
    uint64_t day : 62;
    enum{
        pasture = 0b00,
        stable_in = 0b01,
        stable_out = 0b10
    } id : 2;

    constexpr friend auto operator<=>(const handler_key_t& lhs, const handler_key_t& rhs){
        return std::bit_cast<uint64_t>(lhs) <=> std::bit_cast<uint64_t>(rhs);
    }

    std::string to_string() const
    {
        std::string day_name;
        switch(day)
        {
            case 0: day_name = "monday"; break;
            case 1: day_name = "tuesday"; break;
            case 2: day_name = "wednesday"; break;
            case 3: day_name = "thursday"; break;
            case 4: day_name = "friday"; break;
            case 5: day_name = "saturday"; break;
            case 6: day_name = "sunday"; break;
            default: day_name = fmt::format("invalid ({})", day); break;
        }

        std::string id_name;
        switch(id)
        {
            case pasture: id_name = "pasture"; break;
            case stable_in: id_name = "stable-in"; break;
            case stable_out: id_name = "stable-out"; break;
            default: id_name = fmt::format("invalid ({})", id); break;
        }

        return fmt::format("{} {}", day_name, id_name);
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

std::map<handler_key_t, std::u16string> handlers{};
pthread_rwlock_t handlers_lock{};

enum class client_message_type_e : uint8_t
{
    login = 0,
    get_handler,
    set_handler,
    max
};

enum class server_message_type_e : uint8_t
{
    login_response = 0,
    sent_handler_name,
    max
};

struct server_message_t
{
    std::vector<uint8_t> message_buffer{};

    server_message_t(server_message_type_e message_type, uint64_t data_size)
    {
        message_buffer.resize(data_size + 2);
        message_buffer[0] = static_cast<uint8_t>(message_type);
        message_buffer.back() = END_OF_TRANSMISSION_BLOCK;
    }

    uint8_t* data()
    {
        return message_buffer.data() + 1;
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

ssize_t read_transmission_block(int socket, std::vector<uint8_t>& output)
{
    ssize_t total_nread = 0;

    while(true)
    {
        uint8_t byte;
        ssize_t nread = recv(socket, &byte, 1, 0);
        total_nread += nread;

        if(nread <= 0)
        {
            return nread;
        }

        if(byte == END_OF_TRANSMISSION_BLOCK)
        {
            return total_nread;
        }

        output.push_back(byte);
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

void on_invalid_message(const std::vector<uint8_t>& message, client_t sender)
{
    LOG("recieved invalid message {}. from: {}", message[0], address2string(sender.address));
}

void on_login_request(const std::vector<uint8_t>& message, client_t sender)
{
    constexpr char password[] = "washington";
    auto entered_password = reinterpret_cast<const char*>(&message[1]);

    server_message_t response{server_message_type_e::login_response, 1};
    *response.data() = (std::strcmp(password, entered_password) == 0);

    LOG("login request: {} : {}", address2string(sender.address), *response.data() ? "success" : "failure");

    auto set_login_status = [accepted = *response.data()](client_t* client){
        client->logged_in = accepted;
    };

    if(mutate_client(sender.listener, set_login_status))
    {
        //we dont care if the client disconnects here, its handled in the listener
        (void)send(sender.socket, response.message_buffer.data(), response.message_buffer.size(), MSG_NOSIGNAL);
    }
}

void on_get_handler_request(const std::vector<uint8_t>& message, client_t sender)
{
    if(message.size() != 9)
    {
        on_invalid_message(message, sender);
        return;
    }

    auto key = *reinterpret_cast<const handler_key_t*>(&message[1]);

    LOG("{} requested handler {}", address2string(sender.address), key.to_string());

    pthread_rwlock_wrlock(&handlers_lock);
    std::u16string handler_name = handlers[key];
    pthread_rwlock_unlock(&handlers_lock);

    const uint64_t handler_name_bytes = ((handler_name.size() + 1) * 2);

    server_message_t response{server_message_type_e::sent_handler_name, sizeof(handler_key_t) + handler_name_bytes};
    std::memcpy(response.data(), &key, sizeof(handler_key_t));
    std::memcpy(response.data() + sizeof(handler_key_t), handler_name.data(), handler_name_bytes);

    (void)send(sender.socket, response.message_buffer.data(), response.message_buffer.size(), MSG_NOSIGNAL);
}

void on_set_handler_request(const std::vector<uint8_t>& message, client_t sender)
{
    if(message.size() <= 9)
    {
        on_invalid_message(message, sender);
        return;
    }

    if(!sender.logged_in)
    {
        LOG("{} tried to set a handler name but is not logged in", address2string(sender.address));
        return;
    }

    auto key = *reinterpret_cast<const handler_key_t*>(&message[1]);
    std::u16string handler_name{reinterpret_cast<const char16_t*>(&message[9]), ((message.size() - 9) / 2) - 1};

    LOG("{}: set handler {} to {}", address2string(sender.address), key.to_string(), cvt_str16_to_str8(handler_name));

    pthread_rwlock_wrlock(&handlers_lock);
    handlers[key] = handler_name;
    pthread_rwlock_unlock(&handlers_lock);

    const uint64_t handler_name_bytes = ((handler_name.size() + 1) * 2);

    server_message_t broadcast_message{server_message_type_e::sent_handler_name, sizeof(handler_key_t) + handler_name_bytes};
    std::memcpy(broadcast_message.data(), &key, sizeof(handler_key_t));
    std::memcpy(broadcast_message.data() + sizeof(handler_key_t), handler_name.data(), handler_name_bytes);

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
    while(true)
    {
        client_t client;
        if(!find_client(pthread_self(), &client))
        {
            pthread_exit(nullptr);
        }

        std::vector<uint8_t> message_buffer{};
        ssize_t nread = read_transmission_block(client.socket, message_buffer);

        if(nread <= 0)
        {
            if(nread == 0)
            {
                LOG("client disconnected: {}", address2string(client.address));
            }
            else if(nread == -1)
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
        }
        else
        {
            switch(reinterpret_cast<client_message_type_e&>(message_buffer[0]))
            {
                case client_message_type_e::login:
                    on_login_request(message_buffer, client);
                    break;
                case client_message_type_e::get_handler:
                    on_get_handler_request(message_buffer, client);
                    break;
                case client_message_type_e::set_handler:
                    on_set_handler_request(message_buffer, client);
                    break;
                default:
                    on_invalid_message(message_buffer, client);
                    break;
            }
        }
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