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

#ifndef NDEBUG
#include <fmt/format.h>
#define LOG(message, ...) fmt::print(message "\n" __VA_OPT__(,) __VA_ARGS__)
#else
#define LOG(...) void()
#endif

constexpr uint8_t END_OF_TRANSMISSION_BLOCK = 23;

struct client_t
{
    pthread_t listener = 0;
    int socket = 0;
    sockaddr_in address = {};
    bool logged_in = false;
};

enum class client_message_type_e : uint8_t
{
    login = 0,
    max
};

enum class server_message_type_e : uint8_t
{
    login_response = 0,
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

struct queued_message_t
{
    client_t sender{};
    std::vector<uint8_t> data{};
};

sig_atomic_t shutdown_server = 0;
int server_socket = 0;
std::vector<client_t> clients{};
pthread_rwlock_t clients_lock{};
std::vector<queued_message_t> messages{};
pthread_mutex_t messages_mutex{};
pthread_cond_t messages_condition{};
pthread_t message_consumer_thread{};
pthread_attr_t detached_thread_attr{};

#ifndef NDEBUG
std::string address2string(sockaddr_in address)
{
    return fmt::format("{}:{}", inet_ntoa(address.sin_addr), address.sin_port);
}
#endif

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

void cleanup_pthread_resources() //fixme cant call this as we are "leaking" detached threads
{
    pthread_rwlock_destroy(&clients_lock);
    pthread_mutex_destroy(&messages_mutex);
    pthread_cond_destroy(&messages_condition);
    pthread_attr_destroy(&detached_thread_attr);
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
        ssize_t nread = recv(socket, &byte, 1, 0); //todo optimize
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

void* client_listener(void*)
{
    client_t client;
    if(!find_client(pthread_self(), &client))
    {
        pthread_exit(nullptr);
    }

    while(true)
    {
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
            find_client(pthread_self(), &client); //update our client

            pthread_mutex_lock(&messages_mutex);

            auto& queued_message = messages.emplace_back();
            queued_message.sender = client;
            queued_message.data = std::move(message_buffer);

            pthread_cond_signal(&messages_condition);
            pthread_mutex_unlock(&messages_mutex);
        }
    }
}

void on_login_request(const queued_message_t& message)
{
    constexpr char password[] = "washington";
    auto entered_password = reinterpret_cast<const char*>(&message.data[1]);

    server_message_t response{server_message_type_e::login_response, 1};
    *response.data() = (std::strcmp(password, entered_password) == 0);

    LOG("login request: {} : {}", address2string(message.sender.address), *response.data() ? "success" : "failure");

    auto set_login_status = [accepted = *response.data()](client_t* client){
        client->logged_in = accepted;
    };

    if(mutate_client(message.sender.listener, set_login_status))
    {
        //we dont care if the client disconnects here, its handled in the listener
        (void)send(message.sender.socket, response.message_buffer.data(), response.message_buffer.size(), MSG_NOSIGNAL);
    }
}

void on_invalid_message(const queued_message_t& message)
{
    LOG("recieved invalid message {}. from: {}", message.data[0], address2string(message.sender.address));
}

void* message_consumer(void*)
{
    while(shutdown_server == 0)
    {
        static decltype(messages) messages_copy{};

        pthread_mutex_lock(&messages_mutex);
        while(messages.empty())
        {
            pthread_cond_wait(&messages_condition, &messages_mutex);
        }

        std::swap(messages, messages_copy);
        pthread_mutex_unlock(&messages_mutex);

        for(uint64_t index = 0; index < messages_copy.size(); ++index)
        {
            auto message_handler = [](void* data) -> void*
            {
                auto message = reinterpret_cast<const queued_message_t*>(data);

                switch(*reinterpret_cast<const client_message_type_e*>(&message->data[0]))
                {
                    case client_message_type_e::login:
                        on_login_request(*message);
                        break;
                    default:
                        on_invalid_message(*message);
                        break;
                }

                delete message;
                pthread_exit(nullptr);
            };

            auto new_message = new queued_message_t{std::move(messages_copy[index])};
            pthread_t detach_thread;
            int err = pthread_create(&detach_thread, &detached_thread_attr, message_handler, new_message);
            if(err != 0)
            {
                LOG("error creating message handler thread. err: {}", strerror(err));
                delete new_message;
                pthread_exit(nullptr);
            }
        }

        messages_copy.clear();
    }

    pthread_exit(nullptr);
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

    pthread_rwlock_init(&clients_lock, nullptr);
    pthread_mutex_init(&messages_mutex, nullptr);
    pthread_cond_init(&messages_condition, nullptr);
    pthread_attr_init(&detached_thread_attr);
    pthread_attr_setdetachstate(&detached_thread_attr, PTHREAD_CREATE_DETACHED);

    int consumer_thread_error = pthread_create(&message_consumer_thread, &detached_thread_attr, &message_consumer, nullptr);
    if(consumer_thread_error != 0)
    {
        return EXIT_FAILURE;
    }

    if(atexit(&disconnect_clients) != 0)
    {
        perror("atexit");
        return EXIT_FAILURE;
    }

    while(shutdown_server == 0) //accept clients
    {
        sockaddr_in client_addr;
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
            return EXIT_FAILURE;
        }
    }

    return EXIT_SUCCESS;
}