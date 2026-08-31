// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Bounded exact rolling-window accounting for trader asset spend.
/// @dev Calls in the same block share one record. A trader can create at most 64 distinct
///      spend records per asset in any 24-hour period; exceeding that operational bound fails
///      closed until the oldest record expires.
library AlphaEngineRollingSpendLib {
    uint256 internal constant WINDOW = 24 hours;
    uint256 internal constant MAX_RECORDS = 64;

    struct SpendRecord {
        uint216 amount;
        uint40 timestamp;
    }

    struct SpendWindow {
        uint216 spent;
        uint8 head;
        uint8 count;
        SpendRecord[64] records;
    }

    error SpendRecordCapacityReached(uint256 maximum, uint40 oldestRecordTimestamp);

    function consume(SpendWindow storage window, uint256 amount) internal returns (uint256 total) {
        _prune(window);
        uint256 count = window.count;
        uint40 timestamp = SafeCast.toUint40(block.timestamp);

        if (count != 0) {
            uint256 lastIndex = (uint256(window.head) + count - 1) % MAX_RECORDS;
            SpendRecord storage last = window.records[lastIndex];
            if (last.timestamp == timestamp) {
                last.amount = SafeCast.toUint216(uint256(last.amount) + amount);
                window.spent = SafeCast.toUint216(uint256(window.spent) + amount);
                return window.spent;
            }
        }
        if (count == MAX_RECORDS) {
            revert SpendRecordCapacityReached(MAX_RECORDS, window.records[window.head].timestamp);
        }

        uint256 tail = (uint256(window.head) + count) % MAX_RECORDS;
        window.records[tail] =
            SpendRecord({amount: SafeCast.toUint216(amount), timestamp: timestamp});
        window.count = SafeCast.toUint8(count + 1);
        window.spent = SafeCast.toUint216(uint256(window.spent) + amount);
        total = window.spent;
    }

    function current(SpendWindow storage window) internal view returns (uint256 total) {
        total = window.spent;
        uint256 count = window.count;
        uint256 head = window.head;
        for (uint256 i; i < count; ++i) {
            SpendRecord storage record = window.records[(head + i) % MAX_RECORDS];
            if (uint256(record.timestamp) + WINDOW > block.timestamp) break;
            total -= record.amount;
        }
    }

    function _prune(SpendWindow storage window) private {
        uint256 count = window.count;
        uint256 head = window.head;
        uint256 expiredSpend;
        uint256 expiredCount;
        while (expiredCount < count) {
            uint256 index = (head + expiredCount) % MAX_RECORDS;
            SpendRecord storage record = window.records[index];
            if (uint256(record.timestamp) + WINDOW > block.timestamp) break;
            expiredSpend += record.amount;
            delete window.records[index];
            ++expiredCount;
        }
        if (expiredCount == 0) return;

        window.spent = SafeCast.toUint216(uint256(window.spent) - expiredSpend);
        window.count = SafeCast.toUint8(count - expiredCount);
        window.head = SafeCast.toUint8((head + expiredCount) % MAX_RECORDS);
    }
}
