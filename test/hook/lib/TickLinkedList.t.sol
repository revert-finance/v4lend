// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {TickLinkedList} from "src/hook/lib/TickLinkedList.sol";

contract TickLinkedListTest is Test {
    using TickLinkedList for TickLinkedList.List;

    TickLinkedList.List public increasingList;
    TickLinkedList.List public decreasingList;

    function setUp() public {
        increasingList.increasing = true;
        decreasingList.increasing = false;
    }

    // ============ getFirst Tests ============

    function test_getFirst_EmptyList() public {
        (bool exists, int24 value) = increasingList.getFirst();
        assertFalse(exists);
        assertEq(value, 0);
    }

    function test_getFirst_SingleElement() public {
        assertTrue(increasingList.insert(100, 1));
        (bool exists, int24 value) = increasingList.getFirst();
        assertTrue(exists);
        assertEq(value, 100);
    }

    function test_getFirst_MultipleElements() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(50, 3));
        
        (bool exists, int24 value) = increasingList.getFirst();
        assertTrue(exists);
        assertEq(value, 50); // Should be smallest in increasing order
    }

    // ============ searchFirstAfter Tests ============

    function test_searchFirstAfter_EmptyList() public {
        (bool exists, int24 value) = increasingList.searchFirstAfter(100);
        assertFalse(exists);
        assertEq(value, 0);
    }

    function test_searchFirstAfter_Increasing_SingleElement_Match() public {
        assertTrue(increasingList.insert(100, 1));
        (bool exists, int24 value) = increasingList.searchFirstAfter(100);
        assertFalse(exists); // No tick after 100
        assertEq(value, 0);
    }

    function test_searchFirstAfter_Increasing_SingleElement_Before() public {
        assertTrue(increasingList.insert(100, 1));
        (bool exists, int24 value) = increasingList.searchFirstAfter(50);
        assertTrue(exists);
        assertEq(value, 100); // First tick > 50
    }

    function test_searchFirstAfter_Increasing_SingleElement_After() public {
        assertTrue(increasingList.insert(100, 1));
        (bool exists, int24 value) = increasingList.searchFirstAfter(150);
        assertFalse(exists);
        assertEq(value, 0);
    }

    function test_searchFirstAfter_Increasing_MultipleElements_BeforeAll() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(150, 3));
        
        (bool exists, int24 value) = increasingList.searchFirstAfter(50);
        assertTrue(exists);
        assertEq(value, 100); // First tick > 50
    }

    function test_searchFirstAfter_Increasing_MultipleElements_MatchesFirst() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(150, 3));
        
        (bool exists, int24 value) = increasingList.searchFirstAfter(100);
        assertTrue(exists);
        assertEq(value, 150); // First tick > 100
    }

    function test_searchFirstAfter_Increasing_MultipleElements_Between() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(150, 3));
        
        (bool exists, int24 value) = increasingList.searchFirstAfter(120);
        assertTrue(exists);
        assertEq(value, 150); // First tick > 120
    }

    function test_searchFirstAfter_Increasing_MultipleElements_MatchesMiddle() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(150, 3));
        
        (bool exists, int24 value) = increasingList.searchFirstAfter(150);
        assertTrue(exists);
        assertEq(value, 200); // First tick > 150
    }

    function test_searchFirstAfter_Increasing_MultipleElements_MatchesLast() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(150, 3));
        
        (bool exists, int24 value) = increasingList.searchFirstAfter(200);
        assertFalse(exists); // No tick > 200
        assertEq(value, 0);
    }

    function test_searchFirstAfter_Increasing_MultipleElements_AfterAll() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(150, 3));
        
        (bool exists, int24 value) = increasingList.searchFirstAfter(250);
        assertFalse(exists);
        assertEq(value, 0);
    }

    function test_searchFirstAfter_Increasing_NegativeTicks() public {
        assertTrue(increasingList.insert(-100, 1));
        assertTrue(increasingList.insert(-200, 2));
        assertTrue(increasingList.insert(-150, 3));
        
        (bool exists, int24 value) = increasingList.searchFirstAfter(-180);
        assertTrue(exists);
        assertEq(value, -150); // First tick > -180
        
        (exists, value) = increasingList.searchFirstAfter(-100);
        assertFalse(exists); // No tick > -100
        assertEq(value, 0);
    }

    function test_searchFirstAfter_Increasing_MixedPositiveNegative() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(-100, 2));
        assertTrue(increasingList.insert(0, 3));
        
        (bool exists, int24 value) = increasingList.searchFirstAfter(-50);
        assertTrue(exists);
        assertEq(value, 0); // First tick > -50
        
        (exists, value) = increasingList.searchFirstAfter(50);
        assertTrue(exists);
        assertEq(value, 100); // First tick > 50
    }

    function test_searchFirstAfter_Decreasing_SingleElement_Match() public {
        assertTrue(decreasingList.insert(100, 1));
        (bool exists, int24 value) = decreasingList.searchFirstAfter(100);
        assertFalse(exists); // No tick < 100
        assertEq(value, 0);
    }

    function test_searchFirstAfter_Decreasing_SingleElement_After() public {
        assertTrue(decreasingList.insert(100, 1));
        (bool exists, int24 value) = decreasingList.searchFirstAfter(150);
        assertTrue(exists);
        assertEq(value, 100); // First tick < 150
    }

    function test_searchFirstAfter_Decreasing_SingleElement_Before() public {
        assertTrue(decreasingList.insert(100, 1));
        (bool exists, int24 value) = decreasingList.searchFirstAfter(50);
        assertFalse(exists); // No tick < 50
        assertEq(value, 0);
    }

    function test_searchFirstAfter_Decreasing_MultipleElements_AfterAll() public {
        assertTrue(decreasingList.insert(100, 1));
        assertTrue(decreasingList.insert(200, 2));
        assertTrue(decreasingList.insert(150, 3));
        
        (bool exists, int24 value) = decreasingList.searchFirstAfter(250);
        assertTrue(exists);
        assertEq(value, 200); // First tick < 250
    }

    function test_searchFirstAfter_Decreasing_MultipleElements_MatchesFirst() public {
        assertTrue(decreasingList.insert(100, 1));
        assertTrue(decreasingList.insert(200, 2));
        assertTrue(decreasingList.insert(150, 3));
        
        (bool exists, int24 value) = decreasingList.searchFirstAfter(200);
        assertTrue(exists);
        assertEq(value, 150); // First tick < 200
    }

    function test_searchFirstAfter_Decreasing_MultipleElements_Between() public {
        assertTrue(decreasingList.insert(100, 1));
        assertTrue(decreasingList.insert(200, 2));
        assertTrue(decreasingList.insert(150, 3));
        
        (bool exists, int24 value) = decreasingList.searchFirstAfter(180);
        assertTrue(exists);
        assertEq(value, 150); // First tick < 180
    }

    function test_searchFirstAfter_Decreasing_MultipleElements_MatchesMiddle() public {
        assertTrue(decreasingList.insert(100, 1));
        assertTrue(decreasingList.insert(200, 2));
        assertTrue(decreasingList.insert(150, 3));
        
        (bool exists, int24 value) = decreasingList.searchFirstAfter(150);
        assertTrue(exists);
        assertEq(value, 100); // First tick < 150
    }

    function test_searchFirstAfter_Decreasing_MultipleElements_MatchesLast() public {
        assertTrue(decreasingList.insert(100, 1));
        assertTrue(decreasingList.insert(200, 2));
        assertTrue(decreasingList.insert(150, 3));
        
        (bool exists, int24 value) = decreasingList.searchFirstAfter(100);
        assertFalse(exists); // No tick < 100
        assertEq(value, 0);
    }

    function test_searchFirstAfter_Decreasing_MultipleElements_BeforeAll() public {
        assertTrue(decreasingList.insert(100, 1));
        assertTrue(decreasingList.insert(200, 2));
        assertTrue(decreasingList.insert(150, 3));
        
        (bool exists, int24 value) = decreasingList.searchFirstAfter(50);
        assertFalse(exists);
    }

    function test_searchFirstAfter_Decreasing_NegativeTicks() public {
        assertTrue(decreasingList.insert(-100, 1));
        assertTrue(decreasingList.insert(-200, 2));
        assertTrue(decreasingList.insert(-150, 3));
        
        (bool exists, int24 value) = decreasingList.searchFirstAfter(-120);
        assertTrue(exists);
        assertEq(value, -150); // First tick < -120
        
        (exists, value) = decreasingList.searchFirstAfter(-100);
        assertTrue(exists);
        assertEq(value, -150); // First tick < -100
    }

    function test_searchFirstAfter_EdgeCase_ZeroTick() public {
        assertTrue(increasingList.insert(0, 1));
        assertTrue(increasingList.insert(100, 2));
        assertTrue(increasingList.insert(-100, 3));
        
        (bool exists, int24 value) = increasingList.searchFirstAfter(0);
        assertTrue(exists);
        assertEq(value, 100); // First tick > 0
        
        (exists, value) = increasingList.searchFirstAfter(-50);
        assertTrue(exists);
        assertEq(value, 0); // First tick > -50
    }

    function test_searchFirstAfter_EdgeCase_ExtremeValues() public {
        int24 minTick = type(int24).min;
        int24 maxTick = type(int24).max;
        
        assertTrue(increasingList.insert(0, 1));
        assertTrue(increasingList.insert(maxTick, 2));
        assertTrue(increasingList.insert(minTick, 3));
        
        (bool exists, int24 value) = increasingList.searchFirstAfter(minTick);
        assertTrue(exists);
        assertEq(value, 0); // First tick > minTick
        
        (exists, value) = increasingList.searchFirstAfter(maxTick);
        assertFalse(exists); // No tick > maxTick
        assertEq(value, 0);
    }

    function test_searchFirstAfter_ManyElements() public {
        // Insert many ticks
        for (uint256 i = 0; i < 100; i++) {
            int24 tick = int24(int256(i * 10));
            assertTrue(increasingList.insert(tick, i + 1));
        }
        
        // Test various search points
        (bool exists, int24 value) = increasingList.searchFirstAfter(0);
        assertTrue(exists);
        assertEq(value, 10); // First tick > 0
        
        (exists, value) = increasingList.searchFirstAfter(250);
        assertTrue(exists);
        assertEq(value, 260); // First tick > 250
        
        (exists, value) = increasingList.searchFirstAfter(255);
        assertTrue(exists);
        assertEq(value, 260); // First tick > 255
        
        (exists, value) = increasingList.searchFirstAfter(1000);
        assertFalse(exists);
        assertEq(value, 0);
    }

    // ============ getNext Tests ============

    function test_getNext_Increasing_SingleElement() public {
        assertTrue(increasingList.insert(100, 1));
        (bool exists, int24 value) = increasingList.getNext(100);
        assertFalse(exists);
        assertEq(value, 0);
    }

    function test_getNext_Increasing_MultipleElements_Middle() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(150, 3));
        
        // Order: 100 -> 150 -> 200
        (bool exists, int24 value) = increasingList.getNext(100);
        assertTrue(exists);
        assertEq(value, 150);
        
        (exists, value) = increasingList.getNext(150);
        assertTrue(exists);
        assertEq(value, 200);
    }

    function test_getNext_Increasing_MultipleElements_Last() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(150, 3));
        
        (bool exists, int24 value) = increasingList.getNext(200);
        assertFalse(exists);
        assertEq(value, 0);
    }

    function test_getNext_Decreasing_MultipleElements() public {
        assertTrue(decreasingList.insert(100, 1));
        assertTrue(decreasingList.insert(200, 2));
        assertTrue(decreasingList.insert(150, 3));
        
        // Order: 200 -> 150 -> 100
        (bool exists, int24 value) = decreasingList.getNext(200);
        assertTrue(exists);
        assertEq(value, 150);
        
        (exists, value) = decreasingList.getNext(150);
        assertTrue(exists);
        assertEq(value, 100);
        
        (exists, value) = decreasingList.getNext(100);
        assertFalse(exists);
        assertEq(value, 0);
    }

    // ============ Insert Tests - Increasing ============

    function test_insert_FirstElement() public {
        assertTrue(increasingList.insert(100, 1));
        assertEq(increasingList.size, 1);
        (bool exists, int24 value) = increasingList.getFirst();
        assertTrue(exists);
        assertEq(value, 100);
    }

    function test_insert_IncreasingOrder() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(150, 3));
        
        assertEq(increasingList.size, 3);
        
        // Verify order: 100 -> 150 -> 200
        (bool exists1, int24 val1) = increasingList.getFirst();
        assertTrue(exists1);
        assertEq(val1, 100);
        
        int24 next1 = increasingList.next[val1];
        assertEq(next1, 150);
        
        int24 next2 = increasingList.next[next1];
        assertEq(next2, 200);
        
        int24 next3 = increasingList.next[next2];
        assertEq(next3, 0); // End of list
    }

    function test_insert_AtHead() public {
        assertTrue(increasingList.insert(200, 1));
        assertTrue(increasingList.insert(100, 2)); // Insert at head
        
        (bool exists, int24 value) = increasingList.getFirst();
        assertTrue(exists);
        assertEq(value, 100);
        assertEq(increasingList.next[100], 200);
    }

    function test_insert_AtTail() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2)); // Insert at tail
        
        assertEq(increasingList.next[100], 200);
        assertEq(increasingList.next[200], 0);
    }

    function test_insert_DuplicateTick() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(100, 2)); // Same tick, different tokenId
        
        // Should add tokenId but not increase size
        assertEq(increasingList.size, 1);
        assertEq(increasingList.tokenIds[100].length, 2);
        assertEq(increasingList.tokenIds[100][0], 1);
        assertEq(increasingList.tokenIds[100][1], 2);
    }

    function test_insert_SameTokenIdTwice() public {
        assertTrue(increasingList.insert(100, 1));
        assertFalse(increasingList.insert(100, 1)); // Same tokenId
        
        // Should not add duplicate tokenId
        assertEq(increasingList.size, 1);
        assertEq(increasingList.tokenIds[100].length, 1);
    }

    function test_insert_NegativeTicks() public {
        assertTrue(increasingList.insert(-100, 1));
        assertTrue(increasingList.insert(-200, 2));
        assertTrue(increasingList.insert(-150, 3));
        
        // Verify order: -200 -> -150 -> -100
        (bool exists, int24 value) = increasingList.getFirst();
        assertTrue(exists);
        assertEq(value, -200);
        assertEq(increasingList.next[-200], -150);
        assertEq(increasingList.next[-150], -100);
    }

    function test_insert_MixedPositiveNegative() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(-100, 2));
        assertTrue(increasingList.insert(0, 3));
        
        // Verify order: -100 -> 0 -> 100
        (bool exists, int24 value) = increasingList.getFirst();
        assertTrue(exists);
        assertEq(value, -100);
        assertEq(increasingList.next[-100], 0);
        assertEq(increasingList.next[0], 100);
    }

    // ============ Insert Tests - Decreasing ============

    function test_insert_DecreasingOrder() public {
        assertTrue(decreasingList.insert(100, 1));
        assertTrue(decreasingList.insert(200, 2));
        assertTrue(decreasingList.insert(150, 3));
        
        assertEq(decreasingList.size, 3);
        
        // Verify order: 200 -> 150 -> 100
        (bool exists, int24 value) = decreasingList.getFirst();
        assertTrue(exists);
        assertEq(value, 200);
        
        assertEq(decreasingList.next[200], 150);
        assertEq(decreasingList.next[150], 100);
        assertEq(decreasingList.next[100], 0);
    }

    function test_insert_DecreasingAtHead() public {
        assertTrue(decreasingList.insert(100, 1));
        assertTrue(decreasingList.insert(200, 2)); // Insert at head
        
        (bool exists, int24 value) = decreasingList.getFirst();
        assertTrue(exists);
        assertEq(value, 200);
        assertEq(decreasingList.next[200], 100);
    }

    function test_insert_DecreasingAtTail() public {
        assertTrue(decreasingList.insert(200, 1));
        assertTrue(decreasingList.insert(100, 2)); // Insert at tail
        
        assertEq(decreasingList.next[200], 100);
        assertEq(decreasingList.next[100], 0);
    }

    function test_insert_DecreasingNegativeTicks() public {
        assertTrue(decreasingList.insert(-100, 1));
        assertTrue(decreasingList.insert(-200, 2));
        assertTrue(decreasingList.insert(-150, 3));
        
        // Verify order: -100 -> -150 -> -200
        (bool exists, int24 value) = decreasingList.getFirst();
        assertTrue(exists);
        assertEq(value, -100);
        assertEq(decreasingList.next[-100], -150);
        assertEq(decreasingList.next[-150], -200);
    }

    // ============ Remove Tests - Increasing ============

    function test_remove_EmptyList() public {
        assertFalse(increasingList.remove(100, 1));
    }

    function test_remove_NonExistentTick() public {
        assertTrue(increasingList.insert(100, 1));
        assertFalse(increasingList.remove(200, 1));
        assertEq(increasingList.size, 1);
    }

    function test_remove_NonExistentTokenId() public {
        assertTrue(increasingList.insert(100, 1));
        assertFalse(increasingList.remove(100, 2)); // TokenId doesn't exist
        assertEq(increasingList.size, 1);
        assertEq(increasingList.tokenIds[100].length, 1);
    }

    function test_remove_SingleElement() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.remove(100, 1));
        
        assertEq(increasingList.size, 0);
        (bool exists, int24 value) = increasingList.getFirst();
        assertFalse(exists);
        assertEq(increasingList.head, 0);
    }

    function test_remove_Head() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(150, 3));
        
        assertTrue(increasingList.remove(100, 1));
        
        assertEq(increasingList.size, 2);
        (bool exists, int24 value) = increasingList.getFirst();
        assertTrue(exists);
        assertEq(value, 150); // New head
        assertEq(increasingList.next[150], 200);
    }

    function test_remove_Middle() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(150, 3));
        
        assertTrue(increasingList.remove(150, 3));
        
        assertEq(increasingList.size, 2);
        assertEq(increasingList.next[100], 200);
        assertEq(increasingList.next[200], 0);
    }

    function test_remove_Tail() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(150, 3));
        
        assertTrue(increasingList.remove(200, 2));
        
        assertEq(increasingList.size, 2);
        assertEq(increasingList.next[150], 0); // 150 is now tail
    }

    function test_remove_MultipleTokenIds_SameTick() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(100, 2));
        assertTrue(increasingList.insert(100, 3));
        
        assertEq(increasingList.size, 1);
        assertEq(increasingList.tokenIds[100].length, 3);
        
        // Remove first tokenId
        assertTrue(increasingList.remove(100, 1));
        assertEq(increasingList.size, 1); // Tick still exists
        assertEq(increasingList.tokenIds[100].length, 2);
        
        // Remove second tokenId
        assertTrue(increasingList.remove(100, 2));
        assertEq(increasingList.size, 1); // Tick still exists
        assertEq(increasingList.tokenIds[100].length, 1);
        
        // Remove last tokenId - tick should be removed
        assertTrue(increasingList.remove(100, 3));
        assertEq(increasingList.size, 0); // Tick removed
        assertEq(increasingList.tokenIds[100].length, 0);
    }

    function test_remove_MultipleTokenIds_DifferentTicks() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(150, 3));
        
        assertTrue(increasingList.remove(150, 3));
        assertEq(increasingList.size, 2);
        
        assertTrue(increasingList.remove(100, 1));
        assertEq(increasingList.size, 1);
        
        assertTrue(increasingList.remove(200, 2));
        assertEq(increasingList.size, 0);
    }

    function test_remove_AllTokenIds_SingleElement() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.clearTick(100)); // Remove all tokenIds
        
        assertEq(increasingList.size, 0);
        assertEq(increasingList.tokenIds[100].length, 0);
        (bool exists, int24 value) = increasingList.getFirst();
        assertFalse(exists);
    }

    function test_remove_AllTokenIds_MultipleTokenIds() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(100, 2));
        assertTrue(increasingList.insert(100, 3));
        
        assertEq(increasingList.size, 1);
        assertEq(increasingList.tokenIds[100].length, 3);
        
        assertTrue(increasingList.clearTick(100)); // Remove all tokenIds
        
        assertEq(increasingList.size, 0);
        assertEq(increasingList.tokenIds[100].length, 0);
    }

    function test_remove_AllTokenIds_Head() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(150, 3));
        
        assertTrue(increasingList.clearTick(100)); // Remove all tokenIds at head
        
        assertEq(increasingList.size, 2);
        (bool exists, int24 value) = increasingList.getFirst();
        assertTrue(exists);
        assertEq(value, 150); // New head
        assertEq(increasingList.tokenIds[100].length, 0);
    }

    function test_remove_AllTokenIds_Middle() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(150, 3));
        assertTrue(increasingList.insert(150, 4)); // Multiple tokenIds at middle
        
        assertEq(increasingList.size, 3);
        assertEq(increasingList.tokenIds[150].length, 2);
        
        assertTrue(increasingList.clearTick(150)); // Remove all tokenIds at middle
        
        assertEq(increasingList.size, 2);
        assertEq(increasingList.next[100], 200);
        assertEq(increasingList.tokenIds[150].length, 0);
    }

    function test_remove_AllTokenIds_Tail() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(150, 3));
        assertTrue(increasingList.insert(200, 4)); // Multiple tokenIds at tail
        
        assertEq(increasingList.size, 3);
        assertEq(increasingList.tokenIds[200].length, 2);
        
        assertTrue(increasingList.clearTick(200)); // Remove all tokenIds at tail
        
        assertEq(increasingList.size, 2);
        assertEq(increasingList.next[150], 0); // 150 is now tail
        assertEq(increasingList.tokenIds[200].length, 0);
    }

    function test_remove_AllTokenIds_NonExistentTick() public {
        assertTrue(increasingList.insert(100, 1));
        assertFalse(increasingList.clearTick(200)); // Tick doesn't exist
        assertEq(increasingList.size, 1);
    }

    // ============ Remove Tests - Decreasing ============

    function test_remove_DecreasingHead() public {
        assertTrue(decreasingList.insert(100, 1));
        assertTrue(decreasingList.insert(200, 2));
        assertTrue(decreasingList.insert(150, 3));
        
        assertTrue(decreasingList.remove(200, 2));
        
        assertEq(decreasingList.size, 2);
        (bool exists, int24 value) = decreasingList.getFirst();
        assertTrue(exists);
        assertEq(value, 150); // New head
    }

    function test_remove_DecreasingMiddle() public {
        assertTrue(decreasingList.insert(100, 1));
        assertTrue(decreasingList.insert(200, 2));
        assertTrue(decreasingList.insert(150, 3));
        
        assertTrue(decreasingList.remove(150, 3));
        
        assertEq(decreasingList.size, 2);
        assertEq(decreasingList.next[200], 100);
        assertEq(decreasingList.next[100], 0);
    }

    function test_remove_DecreasingTail() public {
        assertTrue(decreasingList.insert(100, 1));
        assertTrue(decreasingList.insert(200, 2));
        assertTrue(decreasingList.insert(150, 3));
        
        assertTrue(decreasingList.remove(100, 1));
        
        assertEq(decreasingList.size, 2);
        assertEq(decreasingList.next[150], 0);
    }

    function test_remove_Decreasing_AllTokenIds() public {
        assertTrue(decreasingList.insert(100, 1));
        assertTrue(decreasingList.insert(200, 2));
        assertTrue(decreasingList.insert(150, 3));
        assertTrue(decreasingList.insert(150, 4)); // Multiple tokenIds
        
        assertEq(decreasingList.size, 3);
        assertEq(decreasingList.tokenIds[150].length, 2);
        
        assertTrue(decreasingList.clearTick(150)); // Remove all tokenIds at middle
        
        assertEq(decreasingList.size, 2);
        assertEq(decreasingList.next[200], 100);
        assertEq(decreasingList.tokenIds[150].length, 0);
    }

    // ============ Complex Scenarios ============

    function test_ComplexInsertAndRemove() public {
        // Insert multiple ticks
        assertTrue(increasingList.insert(500, 1));
        assertTrue(increasingList.insert(100, 2));
        assertTrue(increasingList.insert(300, 3));
        assertTrue(increasingList.insert(200, 4));
        assertTrue(increasingList.insert(400, 5));
        
        assertEq(increasingList.size, 5);
        
        // Verify order: 100 -> 200 -> 300 -> 400 -> 500
        (bool exists, int24 current) = increasingList.getFirst();
        assertTrue(exists);
        assertEq(current, 100);
        
        current = increasingList.next[current];
        assertEq(current, 200);
        
        current = increasingList.next[current];
        assertEq(current, 300);
        
        current = increasingList.next[current];
        assertEq(current, 400);
        
        current = increasingList.next[current];
        assertEq(current, 500);
        
        // Remove middle elements
        assertTrue(increasingList.remove(200, 4));
        assertTrue(increasingList.remove(400, 5));
        
        assertEq(increasingList.size, 3);
        assertEq(increasingList.next[100], 300);
        assertEq(increasingList.next[300], 500);
        assertEq(increasingList.next[500], 0);
        
        // Remove head
        assertTrue(increasingList.remove(100, 2));
        assertEq(increasingList.size, 2);
        (exists, current) = increasingList.getFirst();
        assertTrue(exists);
        assertEq(current, 300);
        
        // Remove tail
        assertTrue(increasingList.remove(500, 1));
        assertEq(increasingList.size, 1);
        assertEq(increasingList.next[300], 0);
        
        // Remove last element
        assertTrue(increasingList.remove(300, 3));
        assertEq(increasingList.size, 0);
    }

    function test_MultipleTokenIdsPerTick() public {
        // Insert same tick with different tokenIds
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(100, 2));
        assertTrue(increasingList.insert(100, 3));
        assertTrue(increasingList.insert(200, 4));
        
        assertEq(increasingList.size, 2); // Only 2 unique ticks
        assertEq(increasingList.tokenIds[100].length, 3);
        assertEq(increasingList.tokenIds[200].length, 1);

        // Verify tokenIds
        uint256[] memory tokenIds100 = increasingList.tokenIds[100];
        assertEq(tokenIds100[0], 1);
        assertEq(tokenIds100[1], 2);
        assertEq(tokenIds100[2], 3);
        
        // Remove tokenIds one by one
        assertTrue(increasingList.remove(100, 2));
        assertEq(increasingList.size, 2); // Tick still exists
        assertEq(increasingList.tokenIds[100].length, 2);
        
        assertTrue(increasingList.remove(100, 1));
        assertEq(increasingList.size, 2); // Tick still exists
        assertEq(increasingList.tokenIds[100].length, 1);
        
        assertTrue(increasingList.remove(100, 3));
        assertEq(increasingList.size, 1); // Tick removed
        assertEq(increasingList.tokenIds[100].length, 0);

        assertTrue(increasingList.remove(200, 4));
        assertEq(increasingList.size, 0);
        assertEq(increasingList.tokenIds[200].length, 0);
    }

    function test_EdgeCase_ZeroTick() public {
        assertTrue(increasingList.insert(0, 1));
        assertTrue(increasingList.insert(100, 2));
        assertTrue(increasingList.insert(-100, 3));
        
        // Verify order: -100 -> 0 -> 100
        (bool exists, int24 value) = increasingList.getFirst();
        assertTrue(exists);
        assertEq(value, -100);
        assertEq(increasingList.next[-100], 0);
        assertEq(increasingList.next[0], 100);
        
        assertTrue(increasingList.remove(0, 1));
        assertEq(increasingList.next[-100], 100);
    }

    function test_EdgeCase_ExtremeValues() public {
        int24 minTick = type(int24).min;
        int24 maxTick = type(int24).max;
        
        assertTrue(increasingList.insert(0, 1));
        assertTrue(increasingList.insert(maxTick, 2));
        assertTrue(increasingList.insert(minTick, 3));
        
        // Verify order: minTick -> 0 -> maxTick
        (bool exists, int24 value) = increasingList.getFirst();
        assertTrue(exists);
        assertEq(value, minTick);
        assertEq(increasingList.next[minTick], 0);
        assertEq(increasingList.next[0], maxTick);
    }

    function test_TraversalCorrectness() public {
        // Insert in random order
        assertTrue(increasingList.insert(500, 1));
        assertTrue(increasingList.insert(100, 2));
        assertTrue(increasingList.insert(300, 3));
        assertTrue(increasingList.insert(200, 4));
        assertTrue(increasingList.insert(400, 5));
        
        // Traverse and verify all elements
        int24[] memory expected = new int24[](5);
        expected[0] = 100;
        expected[1] = 200;
        expected[2] = 300;
        expected[3] = 400;
        expected[4] = 500;
        
        (bool exists, int24 current) = increasingList.getFirst();
        assertTrue(exists);
        
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(current, expected[i]);
            if (i < expected.length - 1) {
                current = increasingList.next[current];
            } else {
                assertEq(increasingList.next[current], 0);
            }
        }
    }

    function test_DecreasingTraversalCorrectness() public {
        // Insert in random order
        assertTrue(decreasingList.insert(100, 1));
        assertTrue(decreasingList.insert(500, 2));
        assertTrue(decreasingList.insert(300, 3));
        assertTrue(decreasingList.insert(200, 4));
        assertTrue(decreasingList.insert(400, 5));
        
        // Traverse and verify all elements
        int24[] memory expected = new int24[](5);
        expected[0] = 500;
        expected[1] = 400;
        expected[2] = 300;
        expected[3] = 200;
        expected[4] = 100;
        
        (bool exists, int24 current) = decreasingList.getFirst();
        assertTrue(exists);
        
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(current, expected[i]);
            if (i < expected.length - 1) {
                current = decreasingList.next[current];
            } else {
                assertEq(decreasingList.next[current], 0);
            }
        }
    }

    function test_SizeConsistency() public {
        uint32 expectedSize = 0;
        
        // Insert and verify size
        for (uint256 i = 1; i <= 10; i++) {
            assertTrue(increasingList.insert(int24(int256(i * 10)), i));
            expectedSize++;
            assertEq(increasingList.size, expectedSize);
        }
        
        // Remove and verify size
        for (uint256 i = 1; i <= 10; i++) {
            assertTrue(increasingList.remove(int24(int256(i * 10)), i));
            expectedSize--;
            assertEq(increasingList.size, expectedSize);
        }
        
        assertEq(increasingList.size, 0);
    }

    function test_InsertAfterRemove() public {
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.remove(100, 1));
        
        // Insert at the position where 100 was
        assertTrue(increasingList.insert(150, 3));
        
        assertEq(increasingList.size, 2);
        (bool exists, int24 value) = increasingList.getFirst();
        assertTrue(exists);
        assertEq(value, 150);
        assertEq(increasingList.next[150], 200);
    }

    function test_RemoveAllAndReinsert() public {
        // Insert multiple
        assertTrue(increasingList.insert(100, 1));
        assertTrue(increasingList.insert(200, 2));
        assertTrue(increasingList.insert(300, 3));
        
        // Remove all
        assertTrue(increasingList.remove(100, 1));
        assertTrue(increasingList.remove(200, 2));
        assertTrue(increasingList.remove(300, 3));
        
        assertEq(increasingList.size, 0);
        (bool exists, int24 value) = increasingList.getFirst();
        assertFalse(exists);
        
        // Reinsert
        assertTrue(increasingList.insert(500, 4));
        assertEq(increasingList.size, 1);
        (exists, value) = increasingList.getFirst();
        assertTrue(exists);
        assertEq(value, 500);
    }

    // ============ Many Ticks Tests ============

    function test_ManyTicks_InsertAndTraverse() public {
        uint256 numTicks = 100;
        
        // Insert ticks in random order
        for (uint256 i = 0; i < numTicks; i++) {
            int24 tick = int24(int256((i * 37 + 13) % numTicks) * 10 - 500); // Random-ish order
            assertTrue(increasingList.insert(tick, i + 1));
        }
        
        assertEq(increasingList.size, numTicks);
        
        // Verify all ticks are in increasing order
        (bool exists, int24 current) = increasingList.getFirst();
        assertTrue(exists);
        
        int24 prev = current;
        uint32 count = 1;
        
        while (count < numTicks) {
            current = increasingList.next[current];
            assertTrue(current > prev, "Ticks must be in increasing order");
            prev = current;
            count++;
        }
        
        assertEq(increasingList.next[current], 0, "Last tick should point to 0");
    }

    function test_ManyTicks_InsertRemoveRandom() public {
        uint256 numTicks = 200;
        
        // Insert many ticks
        for (uint256 i = 0; i < numTicks; i++) {
            int24 tick = int24(int256(i * 10));
            assertTrue(increasingList.insert(tick, i + 1));
        }
        
        assertEq(increasingList.size, numTicks);
        
        // Remove every 3rd tick
        uint256 removedCount = 0;
        for (uint256 i = 2; i < numTicks; i += 3) {
            int24 tick = int24(int256(i * 10));
            assertTrue(increasingList.remove(tick, i + 1));
            removedCount++;
        }
        
        assertEq(increasingList.size, numTicks - removedCount);
        
        // Verify remaining ticks are still in order
        (bool exists, int24 current) = increasingList.getFirst();
        assertTrue(exists);
        
        int24 prev = current;
        uint32 count = 1;
        uint32 expectedSize = uint32(numTicks - removedCount);
        
        while (count < expectedSize) {
            current = increasingList.next[current];
            assertTrue(current > prev, "Ticks must remain in increasing order after removal");
            prev = current;
            count++;
        }
    }

    function test_ManyTicks_InsertMultipleTokenIds() public {
        uint256 numTicks = 50;
        uint256 tokenIdsPerTick = 5;
        
        // Insert many ticks, each with multiple tokenIds
        for (uint256 i = 0; i < numTicks; i++) {
            int24 tick = int24(int256(i * 10));
            for (uint256 j = 0; j < tokenIdsPerTick; j++) {
                uint256 tokenId = i * tokenIdsPerTick + j + 1;
                assertTrue(increasingList.insert(tick, tokenId));
            }
        }
        
        // Size should equal number of unique ticks, not total tokenIds
        assertEq(increasingList.size, numTicks);
        
        // Verify each tick has correct number of tokenIds
        for (uint256 i = 0; i < numTicks; i++) {
            int24 tick = int24(int256(i * 10));
            assertEq(increasingList.tokenIds[tick].length, tokenIdsPerTick);
        }
        
        // Remove tokenIds one by one from first tick
        int24 firstTick = int24(0);
        for (uint256 j = 0; j < tokenIdsPerTick - 1; j++) {
            uint256 tokenId = j + 1;
            assertTrue(increasingList.remove(firstTick, tokenId));
            assertEq(increasingList.size, numTicks); // Tick still exists
            assertEq(increasingList.tokenIds[firstTick].length, tokenIdsPerTick - j - 1);
        }
        
        // Remove last tokenId from first tick
        assertTrue(increasingList.remove(firstTick, tokenIdsPerTick));
        assertEq(increasingList.size, numTicks - 1); // Tick removed
        assertEq(increasingList.tokenIds[firstTick].length, 0);
    }

    function test_ManyTicks_DecreasingOrder() public {
        uint256 numTicks = 10;
        
        // Insert ticks in random order for decreasing list
        for (uint256 i = 0; i < numTicks; i++) {
            int24 tick = int24(int256((i * 23 + 7) % numTicks) * 10); // Random-ish order
            assertTrue(decreasingList.insert(tick, i + 1));
        }
        
        assertEq(decreasingList.size, numTicks);
        
        // Verify all ticks are in decreasing order
        (bool exists, int24 current) = decreasingList.getFirst();
        assertTrue(exists);
        
        int24 prev = current;
        uint32 count = 1;
        
        while (count < numTicks) {
            current = decreasingList.next[current];
            assertTrue(current < prev, "Ticks must be in decreasing order");
            prev = current;
            count++;
        }
        
        assertEq(decreasingList.next[current], 0, "Last tick should point to 0");
    }

    function test_ManyTicks_RemoveAllFromMiddle() public {
        uint256 numTicks = 100;
        
        // Insert ticks
        for (uint256 i = 0; i < numTicks; i++) {
            int24 tick = int24(int256(i * 10));
            assertTrue(increasingList.insert(tick, i + 1));
        }
        
        // Remove all ticks from middle section
        uint256 startRemove = 30;
        uint256 endRemove = 70;
        
        for (uint256 i = startRemove; i < endRemove; i++) {
            int24 tick = int24(int256(i * 10));
            assertTrue(increasingList.remove(tick, i + 1));
        }
        
        uint256 expectedSize = numTicks - (endRemove - startRemove);
        assertEq(increasingList.size, expectedSize);
        
        // Verify list is still properly linked
        (bool exists, int24 current) = increasingList.getFirst();
        assertTrue(exists);
        
        // First tick should be 0
        assertEq(current, 0);
        
        // Traverse to find where middle section was removed
        uint32 count = 1;
        while (count < startRemove) {
            current = increasingList.next[current];
            count++;
        }
        
        // Next tick should skip to endRemove
        current = increasingList.next[current];
        int24 expectedTick = int24(int256(endRemove * 10));
        assertEq(current, expectedTick, "List should skip removed section");
    }

    function test_ManyTicks_InsertRemoveInsert() public {
        uint256 numTicks = 80;
        
        // Insert ticks
        for (uint256 i = 0; i < numTicks; i++) {
            int24 tick = int24(int256(i * 10));
            assertTrue(increasingList.insert(tick, i + 1));
        }
        
        // Remove half of them
        for (uint256 i = 0; i < numTicks; i += 2) {
            int24 tick = int24(int256(i * 10));
            assertTrue(increasingList.remove(tick, i + 1));
        }
        
        assertEq(increasingList.size, numTicks / 2);
        
        // Insert new ticks in the gaps
        for (uint256 i = 1; i < numTicks; i += 2) {
            int24 tick = int24(int256(i * 10 + 5)); // Insert between existing ticks
            assertTrue(increasingList.insert(tick, numTicks + i));
        }
        
        assertEq(increasingList.size, numTicks);
        
        // Verify order is still correct
        (bool exists, int24 current) = increasingList.getFirst();
        assertTrue(exists);
        
        int24 prev = current;
        uint32 count = 1;
        
        while (count < numTicks) {
            current = increasingList.next[current];
            assertTrue(current > prev, "Ticks must be in increasing order");
            prev = current;
            count++;
        }
    }

    function test_ManyTicks_SizeConsistency() public {
        uint256 numTicks = 250;
        uint32 expectedSize = 0;
        
        // Insert and verify size incrementally
        for (uint256 i = 0; i < numTicks; i++) {
            int24 tick = int24(int256(i * 10));
            assertTrue(increasingList.insert(tick, i + 1));
            expectedSize++;
            assertEq(increasingList.size, expectedSize, "Size should increment on insert");
        }
        
        // Remove and verify size decrementally
        for (uint256 i = 0; i < numTicks; i++) {
            int24 tick = int24(int256(i * 10));
            assertTrue(increasingList.remove(tick, i + 1));
            expectedSize--;
            assertEq(increasingList.size, expectedSize, "Size should decrement on remove");
        }
        
        assertEq(increasingList.size, 0, "List should be empty after removing all");
        (bool exists, int24 value) = increasingList.getFirst();
        assertFalse(exists, "getFirst should return false for empty list");
    }
}
