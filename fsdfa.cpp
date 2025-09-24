#include <iostream>
#include <algorithm>
#include <vector>
#include <cmath>
using namespace std;

int main() {
    int num;
    cin >> num;
    vector<int> digits;
    
    for (int i = 0; i < 4; i++) {
        digits.push_back(num % 10);
        num /= 10;
    }
    
    sort(digits.begin(), digits.end());
    
    if (digits[0] == 0 && digits[1] == 0 && digits[2] == 0) {
        cout << digits[3] * 1000;
    } else if (digits[0] == 0 && digits[1] == 0) {
        cout << digits[2] * 1000 + digits[3];
    } else if (digits[0] == 0) {
        cout << digits[1] * 1000 + digits[2] * 10 + digits[3];
    } else {
        cout << digits[0] * 1000 + digits[1] * 100 + digits[2] * 10 + digits[3];
    }
    
    return 0;
}