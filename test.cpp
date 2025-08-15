#include <gtest/gtest.h>
#include <chrono>
#include <vector>
#include <tuple>
#include "main2.cpp"  


struct MockClock {
    using time_point = std::chrono::system_clock::time_point;
    time_point current_time;

    MockClock() : current_time(std::chrono::system_clock::now()) {}
    void advance(std::chrono::seconds sec) { current_time += sec; }
    time_point now() const { return current_time; }
};

using TestKVStorage = KVStorage<MockClock>;

// Тесты для KVStorage
class KVStorageTest : public ::testing::Test {
protected:
    void SetUp() override {
        // Пример начальных данных: (ключ, значение, TTL в секундах)
        std::vector<std::tuple<std::string, std::string, uint32_t>> entries = {
            {"key1", "value1", 10},  // Истечёт через 10 секунд
            {"key2", "value2", 0},   // Бессрочная запись
            {"key3", "value3", 5}    // Истечёт через 5 секунд
        };
        storage = std::make_unique<TestKVStorage>(entries);
    }

    std::unique_ptr<TestKVStorage> storage;
};


TEST_F(KVStorageTest, SetAndGet) {
    EXPECT_EQ(storage->get("key1"), "value1");
    EXPECT_EQ(storage->get("key2"), "value2");
    EXPECT_EQ(storage->get("key3"), "value3");
    EXPECT_EQ(storage->get("nonexistent"), std::nullopt);
}


TEST_F(KVStorageTest, Expiration) {
    
    storage->clock_.advance(std::chrono::seconds(6));
    
  
    EXPECT_EQ(storage->get("key3"), std::nullopt);
    
  
    EXPECT_EQ(storage->get("key1"), "value1");
    
    
    EXPECT_EQ(storage->get("key2"), "value2");
}


TEST_F(KVStorageTest, Remove) {
    EXPECT_TRUE(storage->remove("key1"));
    EXPECT_EQ(storage->get("key1"), std::nullopt);
    EXPECT_FALSE(storage->remove("nonexistent"));
}


TEST_F(KVStorageTest, GetManySorted) {
    storage->set("a_key", "a_value", 10);
    storage->set("z_key", "z_value", 10);
    
    auto result = storage->getManySorted("a_key", 2);
    ASSERT_EQ(result.size(), 2);
    EXPECT_EQ(result[0].first, "a_key");
    EXPECT_EQ(result[1].first, "key1");  // "key1" был добавлен в SetUp()
}


TEST_F(KVStorageTest, RemoveOneExpiredEntry) {
    
    EXPECT_EQ(storage->removeOneExpiredEntry(), std::nullopt);
    
    
    storage->clock_.advance(std::chrono::seconds(6));
    
    auto expired = storage->removeOneExpiredEntry();
    ASSERT_TRUE(expired.has_value());
    EXPECT_EQ(expired->first, "key3");  
    
    
    EXPECT_EQ(storage->get("key3"), std::nullopt);
}

int main(int argc, char **argv) {
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}