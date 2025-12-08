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
     * @dev Inserts a tick value into the list in sorted order based on increasing field.
     * @param self Stored linked list from contract.
     * @param _tick The tick value to insert.
     * @return bool True if success, false if tick already exists.
     */
    function insert(List storage self, int24 _tick, uint256 _tokenId) internal returns (bool) {

        bool added = _addToTickMapping(self.tokenIds[_tick], _tokenId);
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
        uint32 count = 0;
    
        // Traverse to find insertion point
        if (self.increasing) {
            // Ascending order: find first tick >= _tick
            while (current < _tick && count < self.size) {
                insertAfter = current;
                current = self.next[current];
                count++;
            }
        } else {
            // Descending order: find first tick <= _tick
            while (current > _tick && count < self.size) {
                insertAfter = current;
                current = self.next[current];
                count++;
            }
        }

        bool endReached = count == self.size;

        // tick does not exist or end reached
        if (current != _tick || endReached) {
            self.next[insertAfter] = _tick;
            if (!endReached) {
                self.next[_tick] = current;
            }
            self.size++;
        }

        return true;
    }

    /**
     * @dev Removes a tokenId at a given tick value from the list. If the list is empty after removal, the tick is updated.
     * @param self Stored linked list from contract.
     * @param _tick The tick value.
     * @param _tokenId The tokenId to remove.
     * @return bool True if success, false if tick doesn't exist.
     */
    function remove(List storage self, int24 _tick, uint256 _tokenId) internal returns (bool) {

        if (self.size == 0) {
            return false;
        }

        (bool removed, bool empty) = _removeFromTickMapping(self.tokenIds[_tick], _tokenId);

        if (!removed) {
            return false;
        }

        // If no more tokenIds at this tick, remove the tick from the list
        if (empty) {
            
            int24 nextTick = self.next[_tick];

            // Check if removing head
            if (self.head == _tick) {
                // If this was the only element, set head to 0
                if (self.size == 1) {
                    self.head = 0;
                } else {
                    self.head = nextTick;
                    delete self.next[_tick];
                }
                self.size--;
                return true;
            }

            // Find the previous node by traversing
            int24 prevTick = 0;
            int24 current = self.head;
            uint32 count = 0;
     
            while (current != _tick && count < self.size) {
                prevTick = current;
                current = self.next[current];
                count++;
            }

            if (current != _tick) {
                return false; // Not found
            }

            // Link prev and next together
            self.next[prevTick] = nextTick;

            // Clear the removed node's link
            delete self.next[_tick];
            self.size--;
        }

        return true;
    }

    /// @notice Adds a tokenId to a tick mapping array if not already present
    /// @param tickPositions The storage array reference
    /// @param tokenId The tokenId to add
    /// @return bool True if tokenId was added, false if it was already present
    function _addToTickMapping(uint256[] storage tickPositions, uint256 tokenId) internal returns (bool) {
        uint256 length = tickPositions.length;
        for (uint256 i = 0; i < length; i++) {
            if (tickPositions[i] == tokenId) {
                return false; // Already present
            }
        }
        // Add to array
        tickPositions.push(tokenId);
        return true;
    }

    /// @notice Removes a tokenId from a tick mapping array
    /// @param tickPositions The storage array reference
    /// @param tokenId The tokenId to remove
    /// @return removed True if tokenId was removed, false if it was not present
    /// @return empty True if the array is empty after removal, false otherwise
    function _removeFromTickMapping(uint256[] storage tickPositions, uint256 tokenId) internal returns (bool removed, bool empty) {
        uint256 length = tickPositions.length;
        for (uint256 i = 0; i < length; i++) {
            if (tickPositions[i] == tokenId) {
                // Swap with last element and pop
                tickPositions[i] = tickPositions[length - 1];
                tickPositions.pop();
                return (true, length == 1);
            }
        }
        return (false, length == 0);
    }
}

