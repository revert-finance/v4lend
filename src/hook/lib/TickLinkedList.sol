// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title TickLinkedList
 * @dev A library for managing a sorted single linked list of int24 tick values.
 */
library TickLinkedList {
    struct List {
        bool increasing; // true for ascending order, false for descending order
        uint32 size; // number of initialized ticks
        int24 head; // First element in the list (n/a if size is 0)
        mapping(int24 => int24) next; // Next initialized tick in order
        mapping(int24 => uint256) tokenIdStart; // First active token ID index for each tick
        mapping(int24 => uint256[]) tokenIds; // Token IDs for each tick
    }

    /**
     * @dev Gets the next value in the list, starting from the beginning.
     * @param self Stored linked list from contract.
     * @return bool True if a next value exists, false otherwise.
     * @return int24 The next tick value, or 0 if none exists.
     */
    function getFirst(List storage self) internal view returns (bool, int24) {
        if (self.size == 0) {
            return (false, 0);
        }
        return (true, self.head);
    }

    /**
     * @dev Searches for the first initialized tick after the given tick.
     * @param self Stored linked list from contract.
     * @param tick The tick value to search from.
     * @return bool True if a tick exists after the given tick, false otherwise.
     * @return int24 The first tick after the given tick, or 0 if none exists.
     */
    function searchFirstAfter(List storage self, int24 tick) internal view returns (bool, int24) {
        if (self.size == 0) {
            return (false, 0);
        }

        int24 current = self.head;
        uint32 count = self.size;

        if (self.increasing) {
            // Ascending order: find first tick > tick
            while (current <= tick && count > 0) {
                current = self.next[current];
                count--;
            }
        } else {
            // Descending order: find first tick < tick
            while (current >= tick && count > 0) {
                current = self.next[current];
                count--;
            }
        }

        // If we've traversed the entire list without finding a match
        if (count == 0) {
            return (false, 0);
        }

        return (true, current);
    }

    /**
     * @dev Gets the next initialized tick after the given tick (which is known to exist)
     * @param self Stored linked list from contract.
     * @param tick The tick value to search from.
     * @return bool True if a next tick exists, false otherwise.
     * @return int24 The next tick value, or 0 if none exists.
     */
    function getNext(List storage self, int24 tick) internal view returns (bool, int24) {
        int24 nextTick = self.next[tick];
        bool increasing = self.increasing;

        // handle special case where nextTick is not initialized and points to 0
        if (increasing && nextTick <= tick || !increasing && nextTick >= tick) {
            return (false, 0);
        }

        if (self.tokenIds[nextTick].length == 0) {
            return (false, 0);
        }

        return (true, nextTick);
    }

    /**
     * @dev Inserts a tick value into the list in sorted order based on increasing field.
     * @param self Stored linked list from contract.
     * @param _tick The tick value to insert.
     * @return bool True if success, false if tick already exists.
     */
    function insert(List storage self, int24 _tick, uint256 _tokenId) internal returns (bool) {
        bool added = _addToTickMapping(self.tokenIds[_tick], self.tokenIdStart[_tick], _tokenId);
        if (!added) {
            return false;
        }

        // if empty list, insert at head
        if (self.size == 0) {
            self.head = _tick;
            self.size++;
            return true;
        }

        int24 current = self.head;

        // If the tick is before the current head, insert at the head
        if (self.increasing && _tick < current || !self.increasing && _tick > current) {
            self.next[_tick] = current;
            self.head = _tick;
            self.size++;
            return true;
        }

        // Find the correct position to insert (maintain sorted order based on increasing)
        int24 insertAfter;
        uint32 count = self.size;

        // Traverse to find insertion point
        if (self.increasing) {
            // Ascending order: find first tick >= _tick
            while (current < _tick && count > 0) {
                insertAfter = current;
                current = self.next[current];
                count--;
            }
        } else {
            // Descending order: find first tick <= _tick
            while (current > _tick && count > 0) {
                insertAfter = current;
                current = self.next[current];
                count--;
            }
        }

        // tick does not exist or end reached
        if (current != _tick || count == 0) {
            self.next[insertAfter] = _tick;
            // insert inbetween
            if (count > 0) {
                self.next[_tick] = current;
            }
            self.size++;
        }

        return true;
    }

    /**
     * @dev Removes a tokenId at a given tick value from the list.
     * @param self Stored linked list from contract.
     * @param _tick The tick value.
     * @param _tokenId The tokenId to remove.
     * @return bool True if success, false if tokenid or tick doesn't exist.
     */
    function remove(List storage self, int24 _tick, uint256 _tokenId) internal returns (bool) {
        if (self.size == 0 || _tokenId == 0) {
            return false;
        }

        bool removed;
        bool empty;
        (removed, empty) = _removeFromTickMapping(self.tokenIds[_tick], self.tokenIdStart[_tick], _tokenId);
        if (!removed) {
            return false;
        }

        // If no more tokenIds at this tick, remove the tick node from the linked list.
        if (empty) {
            delete self.tokenIds[_tick];
            delete self.tokenIdStart[_tick];
            return _unlinkTick(self, _tick);
        }

        return true;
    }

    /**
     * @dev Clears all tokenIds at a given tick and removes the tick node from the list.
     * @param self Stored linked list from contract.
     * @param _tick The tick value.
     * @return bool True if success, false if tick doesn't exist.
     */
    function clearTick(List storage self, int24 _tick) internal returns (bool) {
        if (self.size == 0 || self.tokenIds[_tick].length == 0) {
            return false;
        }

        delete self.tokenIds[_tick];
        delete self.tokenIdStart[_tick];
        return _unlinkTick(self, _tick);
    }

    /**
     * @dev Pops up to maxCount tokenIds from a tick without copying the full tick array.
     * Popped entries are not cleared - tokenIdStart just advances past them. Because add()
     * only dedups against the active region [tokenIdStart, length), a popped tokenId that is
     * re-inserted at the same tick (e.g. requeued after a partial pop) is appended again,
     * temporarily duplicating it in the array. This is accepted: duplicates are bounded by
     * the per-swap execution cap and the whole array is deleted once the tick fully drains.
     * @param self Stored linked list from contract.
     * @param _tick The tick value.
     * @param maxCount Maximum number of tokenIds to pop.
     * @return tokenIds Popped tokenIds.
     * @return tickDrained True if no tokenIds remain at the tick.
     */
    function popTokenIds(List storage self, int24 _tick, uint256 maxCount)
        internal
        returns (uint256[] memory tokenIds, bool tickDrained)
    {
        uint256 startIndex = self.tokenIdStart[_tick];
        uint256 length = self.tokenIds[_tick].length;
        uint256 activeLength = length > startIndex ? length - startIndex : 0;
        if (activeLength == 0 || maxCount == 0) {
            tickDrained = activeLength == 0;
            if (tickDrained) {
                delete self.tokenIds[_tick];
                delete self.tokenIdStart[_tick];
                _unlinkTick(self, _tick);
            }
            return (new uint256[](0), tickDrained);
        }

        uint256 count = activeLength < maxCount ? activeLength : maxCount;
        tokenIds = new uint256[](count);
        for (uint256 i; i < count;) {
            tokenIds[i] = self.tokenIds[_tick][startIndex + i];
            unchecked {
                ++i;
            }
        }

        startIndex += count;
        tickDrained = startIndex == length;
        if (tickDrained) {
            delete self.tokenIds[_tick];
            delete self.tokenIdStart[_tick];
            _unlinkTick(self, _tick);
        } else {
            self.tokenIdStart[_tick] = startIndex;
        }
    }

    /// @notice Adds a tokenId to a tick mapping array if not already present
    /// @param tickPositions The storage array reference
    /// @param startIndex First active index in tickPositions
    /// @param tokenId The tokenId to add
    /// @return bool True if tokenId was added, false if it was already present
    function _addToTickMapping(uint256[] storage tickPositions, uint256 startIndex, uint256 tokenId)
        internal
        returns (bool)
    {
        uint256 length = tickPositions.length;
        for (uint256 i = startIndex; i < length;) {
            if (tickPositions[i] == tokenId) {
                return false; // Already present
            }
            unchecked {
                ++i;
            }
        }
        // Add to array
        tickPositions.push(tokenId);
        return true;
    }

    /// @notice Removes a tokenId from a tick mapping array
    /// @param tickPositions The storage array reference
    /// @param startIndex First active index in tickPositions
    /// @param tokenId The tokenId to remove
    /// @return removed True if tokenId was removed, false if it was not present
    /// @return empty True if the array is empty after removal, false otherwise
    function _removeFromTickMapping(uint256[] storage tickPositions, uint256 startIndex, uint256 tokenId)
        internal
        returns (bool removed, bool empty)
    {
        uint256 length = tickPositions.length;
        if (length <= startIndex) {
            return (false, true);
        }

        for (uint256 i = startIndex; i < length;) {
            if (tickPositions[i] == tokenId) {
                // Swap with last element and pop
                tickPositions[i] = tickPositions[length - 1];
                tickPositions.pop();
                return (true, length - 1 == startIndex);
            }
            unchecked {
                ++i;
            }
        }
        return (false, length <= startIndex);
    }

    /// @notice Removes a tick node from the linked list
    /// @param self Stored linked list from contract.
    /// @param _tick The tick value to unlink.
    /// @return bool True if success, false if tick doesn't exist.
    function _unlinkTick(List storage self, int24 _tick) private returns (bool) {
        int24 nextTick = self.next[_tick];

        // Removing head
        if (self.head == _tick) {
            if (self.size == 1) {
                self.head = 0;
            } else {
                self.head = nextTick;
                delete self.next[_tick];
            }
            self.size--;
            return true;
        }

        // Find previous node
        int24 prevTick;
        int24 current = self.head;
        uint32 count = self.size;
        while (current != _tick && count > 0) {
            prevTick = current;
            current = self.next[current];
            count--;
        }

        if (current != _tick) {
            return false;
        }

        self.next[prevTick] = nextTick;
        delete self.next[_tick];
        self.size--;
        return true;
    }
}
