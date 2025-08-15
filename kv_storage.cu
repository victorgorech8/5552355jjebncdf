#include <iostream>
#include <vector>
#include <string>
#include <optional>
#include <chrono>
#include <span>
#include <tuple>
#include <cstring>
#include <thrust/device_vector.h>
#include <thrust/sort.h>
#include <thrust/find.h>
#include <thrust/execution_policy.h>
#include <thrust/copy.h>
#include <thrust/binary_search.h>
#include <thrust/functional.h>

constexpr int MAX_KEY_LEN = 64;
constexpr int MAX_VALUE_LEN = 256;

struct KeyValuePair {
    char key[MAX_KEY_LEN];
    char value[MAX_VALUE_LEN];
    uint32_t ttl;
    int64_t expiration_epoch;

    __host__ __device__
    bool operator<(const KeyValuePair& other) const {
        #ifdef __CUDA_ARCH__
        // Реализация strcmp для устройства
        for (int i = 0; i < MAX_KEY_LEN; ++i) {
            if (key[i] != other.key[i]) return key[i] < other.key[i];
            if (key[i] == '\0') break;
        }
        return false;
        #else
        return strcmp(key, other.key) < 0;
        #endif
    }

    __host__ __device__
    bool operator==(const KeyValuePair& other) const {
        #ifdef __CUDA_ARCH__
        // Реализация strcmp для устройства
        for (int i = 0; i < MAX_KEY_LEN; ++i) {
            if (key[i] != other.key[i]) return false;
            if (key[i] == '\0') break;
        }
        return true;
        #else
        return strcmp(key, other.key) == 0;
        #endif
    }
};

template <typename Clock>
class KVStorage {
public:
    explicit KVStorage(std::span<std::tuple<std::string, std::string, uint32_t>> entries, Clock clock = Clock()) 
        : clock_(clock) {
        std::vector<KeyValuePair> host_data;
        host_data.reserve(entries.size());
        
        auto now = to_epoch(clock_.now());
        
        for (const auto& [key, value, ttl] : entries) {
            KeyValuePair item;
            copy_string(item.key, key, MAX_KEY_LEN);
            copy_string(item.value, value, MAX_VALUE_LEN);
            item.ttl = ttl;
            item.expiration_epoch = ttl == 0 ? std::numeric_limits<int64_t>::max() 
                                           : now + ttl;
            host_data.push_back(item);
        }
        
        data_ = thrust::device_vector<KeyValuePair>(host_data.begin(), host_data.end());
        thrust::sort(thrust::device, data_.begin(), data_.end());
    }

    void set(std::string key, std::string value, uint32_t ttl) {
        auto now = to_epoch(clock_.now());
        KeyValuePair search_item;
        copy_string(search_item.key, key, MAX_KEY_LEN);
        
        // Копируем данные на хост для поиска
        std::vector<KeyValuePair> host_data(data_.begin(), data_.end());
        
        auto it = std::lower_bound(host_data.begin(), host_data.end(), search_item);

        if (it != host_data.end() && *it == search_item) {
            // Обновляем существующую запись
            copy_string(it->value, value, MAX_VALUE_LEN);
            it->ttl = ttl;
            it->expiration_epoch = ttl == 0 ? std::numeric_limits<int64_t>::max() 
                                          : now + ttl;
            
            // Копируем обратно на устройство
            data_ = thrust::device_vector<KeyValuePair>(host_data.begin(), host_data.end());
        } else {
            // Добавляем новую запись
            KeyValuePair new_item;
            copy_string(new_item.key, key, MAX_KEY_LEN);
            copy_string(new_item.value, value, MAX_VALUE_LEN);
            new_item.ttl = ttl;
            new_item.expiration_epoch = ttl == 0 ? std::numeric_limits<int64_t>::max() 
                                               : now + ttl;
            data_.push_back(new_item);
            thrust::sort(thrust::device, data_.begin(), data_.end());
        }
    }

    bool remove(std::string_view key) {
        KeyValuePair search_item;
        copy_string(search_item.key, key, MAX_KEY_LEN);
        
        // Копируем на хост для поиска
        std::vector<KeyValuePair> host_data(data_.begin(), data_.end());
        
        auto it = std::lower_bound(host_data.begin(), host_data.end(), search_item);

        if (it != host_data.end() && *it == search_item) {
            host_data.erase(it);
            data_ = thrust::device_vector<KeyValuePair>(host_data.begin(), host_data.end());
            return true;
        }
        return false;
    }

    std::optional<std::string> get(std::string_view key) const {
        KeyValuePair search_item;
        copy_string(search_item.key, key, MAX_KEY_LEN);
        
        // Копируем на хост для поиска
        std::vector<KeyValuePair> host_data(data_.begin(), data_.end());
        
        auto it = std::lower_bound(host_data.begin(), host_data.end(), search_item);

        auto now = to_epoch(clock_.now());
        
        if (it != host_data.end() && *it == search_item &&
            (it->ttl == 0 || it->expiration_epoch > now)) {
            return std::string(it->value);
        }
        return std::nullopt;
    }

    std::vector<std::pair<std::string, std::string>> getManySorted(std::string_view key, uint32_t count) const {
        std::vector<std::pair<std::string, std::string>> result;
        
        KeyValuePair search_item;
        copy_string(search_item.key, key, MAX_KEY_LEN);
        
        // Копируем на хост для поиска
        std::vector<KeyValuePair> host_data(data_.begin(), data_.end());
        
        auto start = std::lower_bound(host_data.begin(), host_data.end(), search_item);
        auto end = start + std::min<size_t>(count, host_data.end() - start);
        
        auto now = to_epoch(clock_.now());
        for (auto it = start; it != end; ++it) {
            if (it->ttl == 0 || it->expiration_epoch > now) {
                result.emplace_back(it->key, it->value);
            }
        }
        
        return result;
    }

    std::optional<std::pair<std::string, std::string>> removeOneExpiredEntry() {
        auto now = to_epoch(clock_.now());
        
        // Копируем на хост для поиска просроченных
        std::vector<KeyValuePair> host_data(data_.begin(), data_.end());
        
        for (auto it = host_data.begin(); it != host_data.end(); ++it) {
            if (it->ttl != 0 && it->expiration_epoch <= now) {
                auto result = std::make_pair(it->key, it->value);
                host_data.erase(it);
                data_ = thrust::device_vector<KeyValuePair>(host_data.begin(), host_data.end());
                return result;
            }
        }
        
        return std::nullopt;
    }

private:
    thrust::device_vector<KeyValuePair> data_;
    Clock clock_;
    
    static void copy_string(char* dest, std::string_view src, size_t max_len) {
        size_t len = std::min(src.size(), max_len - 1);
        std::copy_n(src.data(), len, dest);
        dest[len] = '\0';
    }
    
    static int64_t to_epoch(const typename Clock::time_point& tp) {
        return std::chrono::duration_cast<std::chrono::seconds>(
            tp.time_since_epoch()).count();
    }
};

// Тестовые часы
struct TestClock {
    using duration = std::chrono::system_clock::duration;
    using rep = duration::rep;
    using period = duration::period;
    using time_point = std::chrono::time_point<TestClock>;
    
    static constexpr bool is_steady = false;
    
    time_point current_time;
    
    TestClock(time_point start = time_point()) : current_time(start) {}
    
    time_point now() const {
        return current_time;
    }
    
    void advance(std::chrono::seconds sec) { 
        current_time += sec; 
    }
};

int main() {
    std::vector<std::tuple<std::string, std::string, uint32_t>> init_data = {
        {"apple", "red", 10},
        {"banana", "yellow", 20},
        {"cherry", "red", 0}
    };
    
    TestClock clock;
    KVStorage<TestClock> storage({init_data}, clock);
    
    storage.set("date", "brown", 15);
    std::cout << "Get 'date': " << storage.get("date").value_or("not found") << std::endl;
    
    auto many = storage.getManySorted("a", 2);
    std::cout << "First 2 keys from 'a':" << std::endl;
    for (const auto& [k, v] : many) {
        std::cout << "  " << k << " = " << v << std::endl;
    }
    
    std::cout << "Remove 'banana': " << (storage.remove("banana") ? "success" : "failed") << std::endl;
    
    std::cout << "Before advance: " << (storage.removeOneExpiredEntry() ? "expired removed" : "no expired") << std::endl;
    clock.advance(std::chrono::seconds(11));
    std::cout << "After 11 seconds: ";
    if (auto expired = storage.removeOneExpiredEntry()) {
        std::cout << "removed " << expired->first << " = " << expired->second << std::endl;
    } else {
        std::cout << "no expired" << std::endl;
    }
    
    return 0;
}