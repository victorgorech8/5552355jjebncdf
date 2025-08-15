
template <typename Clock>
class KVStorage {
public:
    explicit KVStorage(std::span<std::tuple<std::string, std::string, uint32_t>> entries, Clock clock = Clock())
        : clock_(clock) {
        for (const auto& [key, value, ttl] : entries) {
            set(key, value, ttl);
        }
    }

    void set(std::string key, std::string value, uint32_t ttl) {
        auto now = clock_.now();
        TimePoint expiration = (ttl == 0) ? TimePoint::max() : now + std::chrono::seconds(ttl);
        
        auto it = data_.find(key);
        if (it != data_.end()) {
            expiration_index_.erase({it->second.expiration, key});
        }
        
        data_[key] = {std::move(value), expiration};
        expiration_index_.insert({expiration, key});
    }

    bool remove(std::string_view key) {
        auto it = data_.find(std::string(key));
        if (it == data_.end()) {
            return false;
        }
        
        expiration_index_.erase({it->second.expiration, it->first});
        data_.erase(it);
        return true;
    }

    std::optional<std::string> get(std::string_view key) const {
        auto it = data_.find(std::string(key));
        if (it == data_.end() || isExpired(it->second.expiration)) {
            return std::nullopt;
        }
        return it->second.value;
    }

    std::vector<std::pair<std::string, std::string>> getManySorted(std::string_view start_key, uint32_t count) const {
        std::vector<std::pair<std::string, std::string>> result;
        
        auto it = data_.lower_bound(std::string(start_key));
        for (; it != data_.end() && result.size() < count; ++it) {
            if (!isExpired(it->second.expiration)) {
                result.emplace_back(it->first, it->second.value);
            }
        }
        
        return result;
    }

    std::optional<std::pair<std::string, std::string>> removeOneExpiredEntry() {
        auto now = clock_.now();
        auto it = expiration_index_.begin();
        
        if (it != expiration_index_.end() && it->first <= now) {
            auto data_it = data_.find(it->second);
            if (data_it != data_.end()) {
                auto entry = std::make_pair(data_it->first, data_it->second.value);
                data_.erase(data_it);
                expiration_index_.erase(it);
                return entry;
            }
        }
        
        return std::nullopt;
    }

private:
    using TimePoint = decltype(Clock::now());
    
    struct ValueWithExpiration {
        std::string value;
        TimePoint expiration;
    };
    
    std::map<std::string, ValueWithExpiration> data_;
    std::set<std::pair<TimePoint, std::string>> expiration_index_;
    Clock clock_;
    
    bool isExpired(TimePoint expiration) const {
        return expiration != TimePoint::max() && expiration <= clock_.now();
    }
};
