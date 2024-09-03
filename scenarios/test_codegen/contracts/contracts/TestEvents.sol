pragma solidity ^0.8.0;

contract TestEvents {
    event IndexedUint(uint256 indexed num);
    event IndexedInt(int256 indexed num);
    event IndexedAddress(address indexed addr);
    event IndexedBool(bool indexed isTrue);
    event IndexedBytes(bytes indexed dynBytes);
    event IndexedString(string indexed str);
    event IndexedFixedBytes(bytes32 indexed fixedBytes);

    struct TestStruct {
        uint256 id;
        string name;
    }
    event IndexedStruct(TestStruct indexed testStruct);
    event IndexedArray(uint256[] indexed array);
    event IndexedFixedArray(uint256[2] indexed array);
    event IndexedNestedArray(uint256[2][2] indexed array);
    event IndexedStructArray(TestStruct[2] indexed array);

    struct NestedStruct {
        uint256 id;
        TestStruct testStruct;
    }

    event IndexedNestedStruct(NestedStruct indexed nestedStruct);

    struct StructWithArray {
        uint256[] numArr;
        string[2] strArr;
    }

    event IndexedStructWithArray(StructWithArray indexed structWithArray);

    uint256[] public ids;

    function emitTestEvents(
        uint256 id,
        address addr,
        string memory str,
        bool isTrue,
        bytes memory dynBytes,
        bytes32 fixedBytes
    ) public {
        emit IndexedUint(id);
        emit IndexedInt(int(id) * -1);
        emit IndexedAddress(addr);
        emit IndexedBool(isTrue);
        emit IndexedBytes(dynBytes);
        emit IndexedString(str);
        emit IndexedFixedBytes(fixedBytes);
        emit IndexedStruct(TestStruct(id, str));

        ids.push(id);
        ids.push(id + 1);
        emit IndexedArray(ids);
        emit IndexedFixedArray([id, id + 1]);
        emit IndexedNestedArray([[id, id], [id, id]]);
        emit IndexedStructArray([TestStruct(id, str), TestStruct(id, str)]);
        emit IndexedNestedStruct(NestedStruct(id, TestStruct(id, str)));
        emit IndexedStructWithArray(StructWithArray(ids, [str, str]));
    }
}
