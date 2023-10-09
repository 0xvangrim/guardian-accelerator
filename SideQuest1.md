### In the safeTransferFrom function, what does `0x23b872dd000000000000000000000000` represent and what does it mean when used in the following context on line 192: `mstore(0x0c, 0x23b872dd000000000000000000000000)`.

```solidity
mstore(0x0c, 0x23b872dd000000000000000000000000)
```

`0x23b872dd000000000000000000000000` is the function selector of `transferFrom(address,address,uint256)`

We are storing these 16 bytes at the end (at `0x0c`) of the first memory word (word **`0x00`**)

`0x23b872dd000000000000000000000000` is 16 bytes and will be padded with 16 bytes of 0s (32 zeros) in the first memory word starting at `0x0c`

`0x0000000000000000000000000000000023b872dd000000000000000000000000`

By doing so, the 4 bytes of the function selector will be stored at the very end of the word `**0x00**`

The 12 last bytes of zeros will be stored at the beguining of the `**0x20**` memory word

From `**0x20**` to `0x2c`

### In the `safeTransferFrom` function, why is `shl` used on line 191 to shift the `from` to the left by 96 bits?

```solidity
mstore(0x2c, shl(96, from))
```

96 bites correspond to 12 bytes (24 hex)

shl removes the 12 first bytes at the beguining of the address because an address is 20 byes and it will be padded with 12 bytes of zeros (or unexpected hex)

After removing the useless piece of the address, we store it starting at 0x2c (44 in hex), so in the second word (0x20) by an offset of 12 bytes (44 = 32 + 12). The address is stored in 0x20 memory word padded with zeros : 0x000000000000deadbeefdeadbeefdeadbeef

### In the safeTransferFrom function, is this memory safe assembly? Why or why not?

Yes, it seems to be a memory-safe assembly. According to the Solidity docs, assembly is considered to be memory-safe assembly if it only accesses memory ranges following the memory ranges below:
1.Memory is allocated by yourself.
2.Memory is allocated by Solidity.
3.Scratch space is between 0 to 64 bytes.
4.Temporary memory is located after the free memory pointer

At line 188, free memory pointer is cached.

```solidity
let m := mload(0x40)
```

At line 204, free memory pointer is restored to 0x80

```solidity
mstore(0x40, m)
```

The zero slot (0x60) is also restored to zero

### In the safeTransferFrom function, on line 197, why is 0x1c provided as the 4th argument to call?

```solidity
call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
```

\***\*Stack input\*\***

0x1c `argsOffset`: byte offset in the memory in bytes, the calldata of the sub context.

0x64 `argsSize`: byte size to copy (size of the calldata).

We are calling the token with these data:

`0x0000000000000000000000000000000023b872dd0000000000000000000000003f5CE5FBFe3E9af3971dD833D26bA9b5C936f0bE0000000000000000000000000000000000000000000000000000000000000064`

The data in memory starting from `0x1c` (28 in dec) with size `0x64` (100 in dec), meaning from 0x1c until 0x80 (128 = 28 + 100)

In fact we are forwarding all of the 63/64 gas, calling the `transferFrom` function from the token, with the `from` address, the `to` address and the `amount` as arguments.

### In the safeTransfer function, on line 266, why is revert used with 0x1c and 0x04.

```solidity
mstore(0x00, 0x90b8ec18)
```

```solidity
revert(0x1c, 0x04)
```

We are reverting with the last 4 bytes of the memory word 0x00, which correspond to `TransferFailed()`

### In the safeTransfer function, on line 268, why is 0 mstore’d at 0x34.

Because the free memory pointer is the 0x40 word, on line 256 we are storing the amount in 0x34, meaning we are overriding the fmp. We need to restore it at the end.

### In the safeApprove function, on line 317, why is mload(0x00) validated for equality to 1?

mload(0x00) validated for equality to 1 because during the call we are copying a full word (0x20) of returned data. If false (return data from the call) is copied to 0x00, mload(0x00) is falsy so it’s 0, meaning eq(mload(0x00), 1) returns 0 (false)

### In the safeApprove function, if the token returns false from the approve(address,uint256) function, what happens?

The function will revert with `ApproveFailed()`

The selector 0x3e3f8f73 is stored to 0x00 memory word (padded with 28 bytes of zeros), and we revert with the last 4 bytes of the memory word 0x00
