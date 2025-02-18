// SPDX-License-Identifier: MIT

pragma solidity 0.6.8;

import "@cryptogesic/ethereum-contracts-erc20_base/contracts/token/ERC20/IERC20.sol";
import "../../staking/NftStakingV2.sol";

contract NftStakingMock is NftStakingV2 {

    mapping(uint256 => uint64) public weightByTokenAttribute;

    constructor(
        uint32 cycleLengthInSeconds_,
        uint16 periodLengthInCycles_,
        IERC1155721Transferrable whitelistedNftContract_,
        IERC20 rewardsTokenContract_,
        uint256[] memory tokenAttribute,
        uint64[] memory weights
    ) NftStakingV2(
        cycleLengthInSeconds_,
        periodLengthInCycles_,
        whitelistedNftContract_,
        rewardsTokenContract_
    ) public {
        require(tokenAttribute.length == weights.length, "NftStakingMock: inconsistent array lengths");
        for (uint256 i = 0; i < tokenAttribute.length; ++i) {
            weightByTokenAttribute[tokenAttribute[i]] = weights[i];
        }
    }

    function _validateAndGetNftWeight(uint256 nftId) internal virtual override view returns (uint64) {
        uint256 tokenType = nftId >> 240 & 0xFF;
        require(tokenType == 1, "NftStakingMock: Wrong NFT type");
        uint256 attributeValue = nftId >> 176 & 0xFF;
        return weightByTokenAttribute[attributeValue];
    }
}
