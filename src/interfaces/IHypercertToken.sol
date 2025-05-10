// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

interface IHypercertToken {
    /**
     * AllowAll = Unrestricted
     * DisallowAll = Transfers disabled after minting
     * FromCreatorOnly = Only the original creator can transfer
     */
    /// @dev Transfer restriction policies on hypercerts
    enum TransferRestrictions {
        AllowAll,
        DisallowAll,
        FromCreatorOnly
    }

    function splitFraction(address to, uint256 tokenID, uint256[] memory _values) external;
    function unitsOf(uint256 tokenID) external view returns (uint256 units);
    function ownerOf(uint256 tokenID) external view returns (address owner);
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes memory data) external;
    function burnFraction(address from, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function name() external view returns (string memory);
    function mintClaim(address account, uint256 units, string memory uri, TransferRestrictions restrictions) external;
}
