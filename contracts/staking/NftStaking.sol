// SPDX-License-Identifier: MIT

pragma solidity ^0.6.8;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/SafeCast.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@animoca/ethereum-contracts-erc20_base/contracts/token/ERC20/IERC20.sol";
import "@animoca/ethereum-contracts-assets_inventory/contracts/token/ERC721/IERC721.sol";
import "@animoca/ethereum-contracts-assets_inventory/contracts/token/ERC1155/IERC1155.sol";
import "@animoca/ethereum-contracts-assets_inventory/contracts/token/ERC1155/ERC1155TokenReceiver.sol";

abstract contract NftStaking is ERC1155TokenReceiver, Ownable {

    using SafeMath for uint256;
    using SafeCast for uint256;

    uint256 internal constant _DIVS_PRECISION = 10 ** 10;

    event PayoutSet(
        uint256 startPeriod,
        uint256 endPeriod,
        uint128 payoutPerCycle
    );

    event NftStaked(
        address staker,
        uint256 tokenId,
        uint32 cycle
    );

    event NftUnstaked(
        address staker,
        uint256 tokenId,
        uint32 cycle
    );

    event DividendsClaimed(
        address staker,
        uint256 snapshotStartIndex,
        uint256 snapshotEndIndex,
        uint256 amount
    );

    event SnapshotUpdated(
        uint256 index, // index (index-0 based) of the snapshot in the history list
        uint32 startCycle,
        uint32 endCycle,
        uint64 stake // Total stake of all NFTs
    );

    // a struct container used to track aggregate changes in stake over time
    struct Snapshot {
        uint256 period;
        uint32 startCycle;
        uint32 endCycle;
        uint64 stake; // cumulative stake of all NFTs staked
    }

    // a struct container used to track a staker's aggregate staking state
    struct StakerState {
        uint32 nextClaimableCycle;
        uint64 stake;
    }

    struct TokenInfo {
        address owner;
        uint64 depositTimestamp; // seconds since epoch
        uint32 stake;
    }

    bool public disabled = false; // flags whether or not the contract is disabled

    uint256 public startTimestamp = 0; // in seconds since epoch
    uint256 public totalPayout = 0; // payout to be distributed over the entire schedule

    uint256 public immutable cycleLengthInSeconds;
    uint256 public immutable periodLengthInCycles;
    uint256 public immutable freezeDurationAfterStake; // initial duration that a newly staked NFT is locked before it can be with drawn from staking, in seconds

    mapping(address => StakerState) public stakerStates; // staker => StakerState
    mapping(uint256 => TokenInfo) public tokensInfo; // tokenId => TokenInfo
    mapping(uint256 => uint128) public payoutSchedule; // period => payout per-cycle

    Snapshot[] public snapshots; // snapshot history of staking and dividend changes

    address public whitelistedNftContract; // contract that has been whitelisted to be able to perform transfer operations of staked NFTs
    address public dividendToken; // ERC20-based token used in dividend payouts

    modifier divsClaimed(address sender) {
        require(_getUnclaimedPayoutPeriods(sender, periodLengthInCycles) == 0, "NftStaking: Dividends are not claimed");
        _;
    }

    modifier hasStarted() {
        require(startTimestamp != 0, "NftStaking: Staking has not started yet");
        _;
    }

    modifier isEnabled() {
        require(!disabled, "NftStaking: Staking operations are disabled");
        _;
    }

    /**
     * @dev Constructor.
     * @param cycleLengthInSeconds_ Length of a cycle, in seconds.
     * @param periodLengthInCycles_ Length of a dividend payout period, in cycles.
     * @param freezeDurationAfterStake_ Initial duration that a newly staked NFT is locked for before it can be withdrawn from staking, in seconds.
     * @param whitelistedNftContract_ Contract that has been whitelisted to be able to perform transfer operations of staked NFTs.
     * @param dividendToken_ The ERC20-based token used in dividend payouts.
     */
    constructor(
        uint256 cycleLengthInSeconds_,
        uint256 periodLengthInCycles_,
        uint256 freezeDurationAfterStake_,
        address whitelistedNftContract_,
        address dividendToken_
    ) internal {
        require(periodLengthInCycles_ != 0, "NftStaking: Zero payout period length");

        cycleLengthInSeconds = cycleLengthInSeconds_;
        periodLengthInCycles = periodLengthInCycles_;
        freezeDurationAfterStake = freezeDurationAfterStake_;
        whitelistedNftContract = whitelistedNftContract_;
        dividendToken = dividendToken_;
    }

//////////////////////////////////////// Admin Functions //////////////////////////////////////////

    /**
     * Set the payout for a range of periods.
     * @param startPeriod The starting period.
     * @param endPeriod The ending period.
     * @param payoutPerCycle The total payout for each cycle within range.
     */
    function setPayoutForPeriods(
        uint256 startPeriod,
        uint256 endPeriod,
        uint128 payoutPerCycle
    ) public onlyOwner {
        require(startPeriod > 0 && startPeriod <= endPeriod, "NftStaking: wrong period range");

        for (uint256 period = startPeriod; period < endPeriod; ++period) {
            payoutSchedule[period] = payoutPerCycle;
        }

        totalPayout = totalPayout.add(
            (endPeriod.sub(startPeriod) + 1)
            .mul(payoutPerCycle)
            .mul(periodLengthInCycles)
        );

        emit PayoutSet(startPeriod, endPeriod, payoutPerCycle);
    }

    /**
     * Transfers total payout balance to the contract and starts the staking.
     */
    function start() public onlyOwner {
        require(
            IERC20(dividendToken).transferFrom(msg.sender, address(this), totalPayout),
            "NftStaking: failed to transfer the total payout"
        );

        startTimestamp = now;
    }

    /**
     * Withdraws a specified amount of dividend tokens from the contract.
     * @param amount The amount to withdraw.
     */
    function withdrawDivsPool(uint256 amount) public onlyOwner {
        require(IERC20(dividendToken).transfer(msg.sender, amount), "NftStaking: Unknown failure when attempting to withdraw from the dividends reward pool");
    }

    /**
     * Permanently disables all staking and claiming functionality of the contract.
     */
    function disable() public onlyOwner {
        disabled = true;
    }

////////////////////////////////////// ERC1155TokenReceiver ///////////////////////////////////////

    function onERC1155Received(
        address /*operator*/,
        address from,
        uint256 id,
        uint256 /*value*/,
        bytes calldata /*data*/
    )
    external
    virtual
    override
    divsClaimed(from)
    returns (bytes4)
    {
        _stakeNft(id, from);
        return _ERC1155_RECEIVED;
    }

    function onERC1155BatchReceived(
        address /*operator*/,
        address from,
        uint256[] calldata ids,
        uint256[] calldata /*values*/,
        bytes calldata /*data*/
    )
    external
    virtual
    override
    divsClaimed(from)
    returns (bytes4)
    {
        for (uint256 i = 0; i < ids.length; ++i) {
            _stakeNft(ids[i], from);
        }
        return _ERC1155_BATCH_RECEIVED;
    }

//////////////////////////////////// Staking Public Functions /////////////////////////////////////

    /**
     * Unstakes a deposited NFT from the contract.
     * @dev Reverts if the caller is not the original owner of the NFT.
     * @dev While the contract is enabled, reverts if there are outstanding dividends to be claimed.
     * @dev While the contract is enabled, reverts if NFT is being withdrawn before the staking freeze duration has elapsed.
     * @param tokenId The token identifier, referencing the NFT being withdrawn.
     */
    function unstakeNft(uint256 tokenId) external virtual {
        TokenInfo memory tokenInfo = tokensInfo[tokenId];

        require(tokenInfo.owner == msg.sender, "NftStaking: Token owner doesn't match or token was already withdrawn before");

        uint32 currentCycle = getCurrentCycle();

        // by-pass operations if the contract is disabled, to avoid unnecessary calculations and
        // reduce the gas requirements for the caller
        if (!disabled) {
            uint256 periodLengthInCycles_ = periodLengthInCycles;

            require(_getUnclaimedPayoutPeriods(msg.sender, periodLengthInCycles_) == 0, "NftStaking: Dividends are not claimed");
            require(now > tokenInfo.depositTimestamp + freezeDurationAfterStake, "NftStaking: Token is still frozen");

            ensureSnapshots(0);

            uint256 snapshotIndex = snapshots.length - 1;
            Snapshot memory snapshot = snapshots[snapshotIndex];

            // decrease the latest snapshot's stake
            _updateSnapshotStake(
                snapshot,
                snapshotIndex,
                SafeMath.sub(snapshot.stake, tokenInfo.stake).toUint64(),
                currentCycle);

            // clear the token owner to ensure that it cannot be unstaked again
            // without being re-staked
            tokensInfo[tokenId].owner = address(0);

            // decrease the staker's stake
            StakerState memory stakerState = stakerStates[msg.sender];
            stakerState.stake = SafeMath.sub(stakerState.stake, tokenInfo.stake).toUint64();

            // nothing is currently staked by the staker
            if (stakerState.stake == 0) {
                // clear the next claimable cycle
                stakerState.nextClaimableCycle = 0;
            }

            stakerStates[msg.sender] = stakerState;
        }

        try IERC1155(whitelistedNftContract).safeTransferFrom(address(this), msg.sender, tokenId, 1, "") {
        } catch Error(string memory /*reason*/) {
            // This is executed in case evert was called inside
            // getData and a reason string was provided.

            // attempting a non-safe transferFrom() of the token in the case
            // that the failure was caused by a ethereum client wallet
            // implementation that does not support safeTransferFrom()
            IERC721(whitelistedNftContract).transferFrom(address(this), msg.sender, tokenId);
        } catch (bytes memory /*lowLevelData*/) {
            // This is executed in case revert() was used or there was
            // a failing assertion, division by zero, etc. inside getData.

            // attempting a non-safe transferFrom() of the token in the case
            // that the failure was caused by a ethereum client wallet
            // implementation that does not support safeTransferFrom()
            IERC721(whitelistedNftContract).transferFrom(address(this), msg.sender, tokenId);
        }

        emit NftUnstaked(msg.sender, tokenId, currentCycle);
    }

    /**
     * Claims the dividends for the specified number of periods.
     * @param periodsToClaim The maximum number of dividend payout periods to claim for.
     */
    function claimDividends(uint256 periodsToClaim) external isEnabled hasStarted {
        // claiming 0 periods or no snapshots to claim from
        if ((periodsToClaim == 0) || (snapshots.length == 0)) {
            return;
        }

        ensureSnapshots(0);

        StakerState memory stakerState = stakerStates[msg.sender];

        // nothing staked to claim from
        if (stakerState.stake == 0) {
            return;
        }

        uint256 periodLengthInCycles_ = periodLengthInCycles;
        uint256 currentPeriod = _getCurrentPeriod(periodLengthInCycles_);
        uint256 periodToClaim = _getPeriod(stakerState.nextClaimableCycle, periodLengthInCycles_);

        // attempting to claim for the current period. the claim for the current
        // period is always excluded from the claim calculation since it hasn't
        // completed yet
        if (periodToClaim == currentPeriod) {
            return;
        }

        uint256 payoutPerCycle = payoutSchedule[periodToClaim];
        uint256 periodToClaimEndCycle = periodToClaim.mul(periodLengthInCycles_);
        uint128 totalDividendsToClaim = 0;

        (Snapshot memory snapshot, uint256 snapshotIndex) = _findSnapshot(stakerState.nextClaimableCycle);

        // cached for the DividendsClaimed event
        uint256 startSnapshotIndex = snapshotIndex;

        // iterate over snapshots one by one until reaching current period. this
        // loop assumes that (1) there is at least one snapshot within each,
        // (2) snapshots are aligned back-to-back, (3) each period is spanned
        // by snapshots (i.e. no cycle gaps), and (4) snapshots do not span
        // across periods
        while (periodToClaim < currentPeriod) {
            // there are dividends to calculate in this loop iteration
            if ((snapshot.stake != 0) && (payoutPerCycle != 0)) {
                // calculate the staker's snapshot dividends
                uint256 dividendsToClaim = SafeMath.sub(snapshot.endCycle, snapshot.startCycle) + 1;
                dividendsToClaim = dividendsToClaim.mul(payoutPerCycle);
                dividendsToClaim = dividendsToClaim.mul(_DIVS_PRECISION);
                dividendsToClaim = dividendsToClaim.mul(stakerState.stake).div(snapshot.stake);
                dividendsToClaim = dividendsToClaim.div(_DIVS_PRECISION);

                // update the total dividends to claim
                totalDividendsToClaim = SafeMath.add(totalDividendsToClaim, dividendsToClaim).toUint128();
            }

            // snapshot is the last one in the period to claim
            if (snapshot.endCycle == periodToClaimEndCycle) {
                // advance the period state for the next loop iteration
                ++periodToClaim;
                payoutPerCycle = payoutSchedule[periodToClaim];
                periodToClaimEndCycle = periodToClaim.mul(periodLengthInCycles_);
            }

            // advance the snapshot for the next loop iteration
            ++snapshotIndex;
            snapshot = snapshots[snapshotIndex];

            // all requested periods to claim have been made. checking the
            // periods to claim at the end of the loop cycle to ensure that
            // the exiting state is consistent across all terminating loop
            // conditions
            if (--periodsToClaim == 0) {
                break;
            }
        }

        // loop will exit with its loop variables updated for the next
        // claimable period/snapshot/cycle

        // advance the staker's next claimable cycle for each call of this
        // function. this should be done even when no dividends to claim were
        // found, to save from reprocessing fruitless periods in subsequent
        // calls
        stakerStates[msg.sender].nextClaimableCycle = snapshot.startCycle;

        // no dividends to claim were found across the processed periods
        if (totalDividendsToClaim == 0) {
            return;
        }

        require(
            IERC20(dividendToken).transfer(msg.sender, totalDividendsToClaim),
            "NftStaking: Unknown failure when attempting to transfer claimed dividend rewards");

        emit DividendsClaimed(
            msg.sender,
            startSnapshotIndex,
            snapshotIndex - 1,
            totalDividendsToClaim);
    }

    /**
     * @dev if the latest snapshot is related to a past period, creates a
     * snapshot for each missing past period (if any) and one for the
     * current period (if needed). Updates the latest snapshot to end on
     * current cycle if not already.
     * @param maxSnapshotsToAdd the limit of snapshots to create. No limit
     * will be applied if it equals zero.
     */
    function ensureSnapshots(uint256 maxSnapshotsToAdd) public {
        uint256 periodLengthInCycles_ = periodLengthInCycles;
        uint32 currentCycle = _getCycle(now);
        uint256 currentPeriod = _getPeriod(currentCycle, periodLengthInCycles_);
        uint256 totalSnapshots = snapshots.length;

        // no snapshots currently exist
        if (totalSnapshots == 0) {
            // create the initial snapshot, starting at the current cycle
            _addNewSnapshot(currentPeriod, currentCycle, currentCycle, 0);
            return;
        }

        uint256 snapshotIndex = totalSnapshots - 1;

        // get the latest snapshot
        Snapshot storage writeSnapshot = snapshots[snapshotIndex];

        // in-memory copy of the latest snapshot for reads, to save gas
        Snapshot memory readSnapshot = writeSnapshot;

        // latest snapshot ends on the current cycle
        if (readSnapshot.endCycle == currentCycle) {
            // nothing to do
            return;
        }

        // determine the assignment based on whether or not the latest snapshot
        // is in the current period
        uint32 snapshotPeriodEndCycle =
            readSnapshot.period == currentPeriod ?
                currentCycle :
                readSnapshot.period.mul(periodLengthInCycles_).toUint32();

        // extend the latest snapshot to cover all of the missing cycles for its
        // period
        writeSnapshot.endCycle = snapshotPeriodEndCycle;
        readSnapshot.endCycle = snapshotPeriodEndCycle;

        emit SnapshotUpdated(
                snapshotIndex,
                readSnapshot.startCycle,
                readSnapshot.endCycle,
                readSnapshot.stake);

        // latest snapshot was for the current period
        if (readSnapshot.period == currentPeriod) {
            // we are done
            return;
        }

        // latest snapshot is in an earlier period

        uint256 previousPeriod = currentPeriod - 1;
        bool hasAddNewSnapshotLimit = maxSnapshotsToAdd != 0;

        // while there are unaccounted-for periods...
        while (readSnapshot.period < previousPeriod) {
            // maximum snapshots to add has been reached
            if (hasAddNewSnapshotLimit && (--maxSnapshotsToAdd == 0)) {
                // break out of loop to add the last snapshot for the current
                // period
                break;
            }

            // create an interstitial snapshot that spans the unaccounted-for
            // period, initialized with the staked weight of the previous
            // snapshot
            (writeSnapshot, snapshotIndex) = _addNewSnapshot(
                readSnapshot.period + 1,
                readSnapshot.endCycle + 1,
                (readSnapshot.endCycle + periodLengthInCycles_).toUint32(),
                readSnapshot.stake);

            readSnapshot = writeSnapshot;
        }

        // create the new latest snapshot for the current period and cycle,
        // initialized with the staked weight from the previous snapshot
        _addNewSnapshot(
            readSnapshot.period + 1,
            readSnapshot.endCycle + 1,
            currentCycle,
            readSnapshot.stake);
    }

    /**
     * Retrieves the current cycle (index-1 based).
     * @return The current cycle (index-1 based).
     */
    function getCurrentCycle() public view returns(uint32) {
        // index is 1 based
        return _getCycle(now);
    }

    /**
     * Retrieves the current payout period (index-1 based).
     * @return The current payout period (index-1 based).
     */
    function getCurrentPayoutPeriod() external view returns(uint256) {
        return _getCurrentPeriod(periodLengthInCycles);
    }

    /**
     * Retrieves the first unclaimed payout period (index-1 based) and number of unclaimed payout periods.
     * @return The first unclaimed payout period (index-1 based).
     * @return The number of unclaimed payout periods.
     */
    function getUnclaimedPayoutPeriods() external view returns(uint256, uint256) {
        StakerState memory stakerState = stakerStates[msg.sender];
        uint256 periodLengthInCycles_ = periodLengthInCycles;
        return (
            _getPeriod(stakerState.nextClaimableCycle, periodLengthInCycles_),
            _getUnclaimedPayoutPeriods(msg.sender, periodLengthInCycles_)
        );
    }

//////////////////////////////////// Staking Internal Functions /////////////////////////////////////

    /**
     * Adds a new dividends snapshot to the snapshot history list.
     * @param cycleStart Starting cycle for the new snapshot.
     * @param cycleEnd Ending cycle for the new snapshot.
     * @param stake Initial stake for the new snapshot.
     * @return The newly created snapshot.
     * @return The index of the newly created snapshot.
     */
    function _addNewSnapshot(
        uint256 period,
        uint32 cycleStart,
        uint32 cycleEnd,
        uint64 stake
    ) internal returns(Snapshot storage, uint256)
    {
        Snapshot memory snapshot;
        snapshot.period = period;
        snapshot.startCycle = cycleStart;
        snapshot.endCycle = cycleEnd;
        snapshot.stake = stake;

        snapshots.push(snapshot);

        uint256 snapshotIndex = snapshots.length - 1;

        emit SnapshotUpdated(
            snapshotIndex,
            snapshot.startCycle,
            snapshot.endCycle,
            snapshot.stake);

        return (snapshots[snapshotIndex], snapshotIndex);
    }

    /**
     * Retrieves the cycle (index-1 based) at the specified timestamp.
     * @param ts The timestamp for which the cycle is derived from.
     * @return The cycle (index-1 based) at the specified timestamp.
     */
    function _getCycle(uint256 ts) internal view returns(uint32) {
        return (ts.sub(startTimestamp).div(cycleLengthInSeconds) + 1).toUint32();
    }

     /**
      * Retrieves the current payout period (index-1 based).
      * @param periodLengthInCycles_ Length of a dividend payout period, in cycles.
      * @return The current payout period (index-1 based).
      */
    function _getCurrentPeriod(uint256 periodLengthInCycles_) internal view returns(uint256) {
        return _getPeriod(getCurrentCycle(), periodLengthInCycles_);
    }

    /**
     * Retrieves the payout period (index-1 based) for the specified cycle and payout period length.
     * @param cycle The cycle within the payout period to retrieve.
     * @param periodLengthInCycles_ Length of a dividend payout period, in cycles.
     * @return The payout period (index-1 based) for the specified cycle and payout period length.
     */
    function _getPeriod(uint32 cycle, uint256 periodLengthInCycles_) internal pure returns(uint256) {
        if (cycle == 0) {
            return 0;
        }
        // index is 1 based
        return SafeMath.div(cycle - 1, periodLengthInCycles_) + 1;
    }

    /**
     * Retrieves the number of unclaimed payout periods for the specified staker.
     * @param sender The staker whose number of unclaimed payout periods will be retrieved.
     * @param periodLengthInCycles_ Length of a dividend payout period, in cycles.
     * @return The number of unclaimed payout periods for the specified staker.
     */
    function _getUnclaimedPayoutPeriods(address sender, uint256 periodLengthInCycles_) internal view returns(uint256) {
        StakerState memory stakerState = stakerStates[sender];
        if (stakerState.stake == 0) {
            return 0;
        }

        uint256 periodToClaim = _getPeriod(stakerState.nextClaimableCycle, periodLengthInCycles_);
        return _getCurrentPeriod(periodLengthInCycles_).sub(periodToClaim);
    }

    /**
     * Updates the snapshot stake at the current cycle. It will update the
     * latest snapshot if it starts at the current cycle, otherwise will adjust
     * the snapshots range end back by one cycle (the previous cycle) and
     * create a new snapshot for the current cycle with the stake update.
     * @param snapshot The snapshot whose stake is being updated.
     * @param snapshotIndex The index of the snapshot being updated.
     * @param stake The stake to update the latest snapshot with.
     * @param currentCycle The current staking cycle.
     */
    function _updateSnapshotStake(
        Snapshot memory snapshot,
        uint256 snapshotIndex,
        uint64 stake,
        uint32 currentCycle
    ) internal
    {
        if (snapshot.startCycle == currentCycle) {
            // if the snapshot starts at the current cycle, update its stake
            // since this is the only time we can update an existing snapshot
            snapshots[snapshotIndex].stake = stake;

            emit SnapshotUpdated(
                snapshotIndex,
                snapshot.startCycle,
                snapshot.endCycle,
                stake);

        } else {
            // make the current snapshot end at previous cycle, since the stake
            // for a new snapshot at the current cycle will be updated
            --snapshots[snapshotIndex].endCycle;

            // Note: no need to emit the SnapshotUpdated event, from adjusting
            // the snapshot range, since the purpose of the event is to report
            // changes in stake weight

            // add a new snapshot starting at the current cycle with stake
            // update
            _addNewSnapshot(snapshot.period, currentCycle, currentCycle, stake);
        }
    }

    /**
     * Stakes the NFT received by the contract, referenced by its specified token identifier and owner.
     * @param tokenId Identifier of the staked NFT.
     * @param tokenOwner Owner of the staked NFT.
     */
    function _stakeNft(
        uint256 tokenId,
        address tokenOwner
    ) internal isEnabled hasStarted {
        require(whitelistedNftContract == msg.sender, "NftStaking: Caller is not the whitelisted NFT contract");

        uint32 nftWeight = _validateAndGetWeight(tokenId);

        ensureSnapshots(0);

        uint32 currentCycle = getCurrentCycle();
        uint256 snapshotIndex = snapshots.length - 1;
        Snapshot memory snapshot = snapshots[snapshotIndex];

        // increase the latest snapshot's stake
        _updateSnapshotStake(
            snapshot,
            snapshotIndex,
            SafeMath.add(snapshot.stake, nftWeight).toUint64(),
            currentCycle);

        // set the staked token's info
        TokenInfo memory tokenInfo;
        tokenInfo.depositTimestamp = now.toUint64();
        tokenInfo.owner = tokenOwner;
        tokenInfo.stake = nftWeight;
        tokensInfo[tokenId] = tokenInfo;

        StakerState memory stakerState = stakerStates[tokenOwner];

        if (stakerState.stake == 0) {
            // nothing is currently staked by the staker so reset/initialize
            // the next claimable cycle to the current cycle for unclaimed
            // payout period tracking
            stakerState.nextClaimableCycle = currentCycle;
        }

        // increase the staker's stake
        stakerState.stake = SafeMath.add(stakerState.stake, nftWeight).toUint64();
        stakerStates[tokenOwner] = stakerState;

        emit NftStaked(tokenOwner, tokenId, currentCycle);
    }

    /**
     * Searches for the dividend snapshot containing the specified cycle. If the snapshot cannot be found then the closest snapshot by cycle range is returned.
     * @param cycle The cycle for which the dividend snapshot is searched for.
     * @return snapshot If found, the snapshot containing the specified cycle, otherwise the closest snapshot to the cycle.
     * @return snapshotIndex The index (index-0 based) of the returned snapshot.
     */
    function _findSnapshot(uint32 cycle)
    internal
    view
    returns(Snapshot memory snapshot, uint256 snapshotIndex)
    {
        uint256 low = 0;
        uint256 high = snapshots.length - 1;
        uint256 mid = 0;

        while (low <= high) {
            // overflow protected midpoint calculation
            mid = low.add(high.sub(low).div(2));

            snapshot = snapshots[mid];

            if (snapshot.startCycle > cycle) {
                if (mid == 0) {
                    break;
                }

                // outside by left side of the range
                high = mid - 1;
            } else if (snapshot.endCycle < cycle) {
                if (mid == type(uint256).max) {
                    break;
                }

                // outside by right side of the range
                low = mid + 1;
            } else {
                break;
            }
        }

        // return snapshot with cycle within range or closest possible to it
        return (snapshot, mid);
    }

    /**
     * Abstract function which validates whether or not the supplied NFT identifier is accepted for staking
     * and retrieves its associated weight. MUST throw if the token is invalid.
     * @param nftId uint256 NFT identifier used to determine if the token is valid for staking.
     * @return uint32 the weight of the NFT.
     */
    function _validateAndGetWeight(uint256 nftId) internal virtual view returns (uint32);

}
