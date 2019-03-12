// Copyright (C) 2019 David Terry <me@xwvvvvwx.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.0 <0.6.0;

import "ds-test/test.sol";

import "./pause.sol";

// ------------------------------------------------------------------
// Test Harness
// ------------------------------------------------------------------

contract Hevm {
    function warp(uint) public;
}

contract Target {
    function getBytes32() public pure returns (bytes32) {
        return bytes32("Hello");
    }
}

contract Stranger {
    function call(address target, bytes memory data) public returns (bytes memory) {
        (bool success, bytes memory result) = target.call(data);

        require(success);
        return result;
    }
}

contract Authority is DSAuthority {
    address owner;

    constructor() public {
        owner = msg.sender;
    }

    function canCall(address src, address, bytes4)
        public
        view
        returns (bool)
    {
        require(src == owner);
        return true;
    }
}

// ------------------------------------------------------------------
// Common Setup
// ------------------------------------------------------------------

contract Test is DSTest {
    DSPause pause;
    Target target;
    Hevm hevm;
    Stranger stranger;

    uint start = 1;
    uint delay = 1;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(start);

        target = new Target();
        pause = new DSPause(delay, address(0x0), new Authority());
        stranger = new Stranger();
    }
}

// ------------------------------------------------------------------
// Tests
// ------------------------------------------------------------------

contract Constructor is DSTest {

    function test_delay_set() public {
        DSPause pause = new DSPause(100, address(0x0), new Authority());
        assertEq(pause.delay(), 100);
    }

    function test_owner_set() public {
        DSPause pause = new DSPause(100, address(0xdeadbeef), address(0x0));
        assertEq(address(pause.owner()), address(0xdeadbeef));
    }

    function test_authority_set() public {
        Authority authority = new Authority();
        DSPause pause = new DSPause(100, address(0x0), authority);
        assertEq(address(pause.authority()), address(authority));
    }

}

contract SetAuthority {
    function set(DSAuth user, DSAuthority authority) public {
        user.setAuthority(authority);
    }
}

contract SetOwner {
    function set(DSAuth user, address owner) public {
        user.setOwner(owner);
    }
}

contract Auth is Test {

    function testFail_cannot_set_owner_without_delay() public {
        pause.setOwner(address(this));
    }

    function test_set_owner_with_delay() public {
        SetOwner setOwner = new SetOwner();

        bytes memory payload = abi.encodeWithSignature("set(address,address)", pause, 0xdeadbeef);
        (address who, bytes memory data, uint when) = pause.plan(address(setOwner), payload);

        hevm.warp(now + delay);
        pause.exec(who, data, when);

        assertEq(address(pause.owner()), address(0xdeadbeef));
    }

    function testFail_cannot_set_authority_without_delay() public {
        pause.setAuthority(new Authority());
    }

    function test_set_authority_with_delay() public {
        SetAuthority setAuthority = new SetAuthority();
        Authority newAuthority = new Authority();

        bytes memory payload = abi.encodeWithSignature("set(address,address)", pause, newAuthority);
        (address who, bytes memory data, uint when) = pause.plan(address(setAuthority), payload);

        hevm.warp(now + delay);
        pause.exec(who, data, when);

        assertEq(address(pause.authority()), address(newAuthority));
    }
}

contract Plan is Test {

    function testFail_call_from_non_owner() public {
        bytes memory data = abi.encodeWithSignature("plan(address,bytes)", address(target), abi.encode(0));
        stranger.call(address(pause), data);
    }

    function test_plan() public {
        bytes memory data = abi.encodeWithSignature("getBytes32()");

        (address user, _, uint when) = pause.plan(address(target), data);

        bytes32 id = keccak256(abi.encode(user, data, when));
        assertTrue(pause.plans(id));
    }

    function test_return_values() public {
        bytes memory dataIn = abi.encodeWithSignature("getBytes32()");

        (address user, bytes memory dataOut, uint when) = pause.plan(address(target), dataIn);

        assertEq0(dataIn, dataOut);
        assertEq(user, address(target));
        assertEq(when, now);
    }

}

contract Exec is Test {

    function testFail_delay_not_passed() public {
        (address user, bytes memory data, uint when) = pause.plan(address(target), abi.encode(0));
        pause.exec(user, data, when);
    }

    function testFail_double_execution() public {
        (address user, bytes memory data, uint when) = pause.plan(address(target), abi.encodeWithSignature("getBytes32()"));
        hevm.warp(now + delay);

        pause.exec(user, data, when);
        pause.exec(user, data, when);
    }

    function test_exec_delay_passed() public {
        (address user, bytes memory data, uint when) = pause.plan(address(target), abi.encodeWithSignature("getBytes32()"));
        hevm.warp(now + delay);

        bytes memory response = pause.exec(user, data, when);

        bytes32 response32;
        assembly {
            response32 := mload(add(response, 32))
        }
        assertEq(response32, bytes32("Hello"));
    }

    function test_call_from_non_owner() public {
        (address user, bytes memory data, uint when) = pause.plan(address(target), abi.encodeWithSignature("getBytes32()"));
        hevm.warp(now + delay);

        stranger.call(address(pause), abi.encodeWithSignature("exec(address,bytes,uint256)", user, data, when));
    }

}

contract Drop is Test {

    function testFail_call_from_non_owner() public {
        (address user, bytes memory data, uint when) = pause.plan(address(target), abi.encodeWithSignature("getBytes32()"));
        hevm.warp(now + delay);

        bytes memory payload = abi.encodeWithSignature("drop(address,bytes,uint256)", user, data, when);
        stranger.call(address(pause), payload);
    }

    function test_drop_planned_execution() public {
        (address user, bytes memory data, uint when) = pause.plan(address(target), abi.encodeWithSignature("getBytes32()"));
        hevm.warp(now + delay);

        pause.drop(user, data, when);

        bytes32 id = keccak256(abi.encode(user, data, when));
        assertTrue(!pause.plans(id));
    }

}
