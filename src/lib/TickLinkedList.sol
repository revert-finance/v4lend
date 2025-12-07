// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title TickLinkedList
 * @dev A library for managing sorted linked lists of int24 tick values.
 * Based on StructuredLinkedList by Vittorio Minacori (https://github.com/vittominacori/solidity-linked-list)
 */
library TickLinkedList {
    struct List {
        bool increasing; // true for ascending order, false for descending order
        uint32 size; // number of items in the list
        int24 head; // First element in the list (0 if empty)
        mapping(int24 => int24) next; // Next element (0 if end of list)
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
    function insert(List storage self, int24 _tick) internal returns (bool) {

        if (self.size == 0) {
            self.head = _tick;
            self.size = 1;
            return true;
        }

        // Find the correct position to insert (maintain sorted order based on increasing)
        int24 current = self.head;
        int24 insertAfter = 0; // 0 means insert at head

        // Traverse to find insertion point
        if (self.increasing) {
            // Ascending order: find first tick >= _tick
            while (current != 0 && current < _tick) {
                insertAfter = current;
                current = self.next[current];
            }
        } else {
            // Descending order: find first tick <= _tick
            while (current != 0 && current > _tick) {
                insertAfter = current;
                current = self.next[current];
            }
        }

        if (current == _tick) {
            return false; // Tick already exists
        }

        // Insert after insertAfter, before current
        if (insertAfter == 0) {
            // Insert at head
            self.next[_tick] = self.head;
            self.head = _tick;
        } else {
            self.next[insertAfter] = _tick;
            self.next[_tick] = current;
        }
        self.size++;

        return true;
    }

    /**
     * @dev Removes a tick value from the list.
     * @param self Stored linked list from contract.
     * @param _tick The tick value to remove.
     * @return bool True if success, false if tick doesn't exist.
     */
    function remove(List storage self, int24 _tick) internal returns (bool) {

        if (self.size == 0) {
            return false;
        }

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

        return true;
    }
}

