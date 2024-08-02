//SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./EnumerableSet.sol";
import "./Ownable.sol";
import "./IERC20.sol";

interface IFeeRecipient {
    function takeFee(uint256 amount, uint8 tier) external;
}

contract ControlStaking is Ownable {

    // name and symbol for tokenized contract
    string private constant _name = "Staked CONTROL";
    string private constant _symbol = "SCTRL";
    uint8 private constant _decimals = 18;
    
    // precision constant to reduce round-off errors
    uint256 private constant precision = 10**18;

    // recipient of fee
    address public feeRecipient;

    // Staking Token
    address public immutable token;

    // Reward Token
    address public reward;

    // Tiers
    struct Tier {

        /** total tokens staked in this tier */
        uint256 totalShares;

        /** total rewards given to this tier thus far */
        uint256 totalRewards;

        /** reward tracking data for this tier */
        uint256 rewardsPerShare;

        /** Lock Time */
        uint256 lockTime;

        /** Leave Early Fee */
        uint256 leaveEarlyFee;

        /** Maps an address to the amount they have staked in this tier */
        mapping ( address => uint256 ) tierStaked;
        mapping ( address => uint256 ) totalExcluded;
    }

    // Maps a tierId to a Tier Data Structure
    mapping ( uint8 => Tier ) private tiers;

    // Lock Id
    struct LockId {
        address user;
        uint256 totalLocked;
        uint256 currentAmount;
        uint256 unlockTime;
        uint8 tier;
    }

    // Maps lockId to Lock
    mapping ( uint256 => LockId ) public lockInfo;

    // User Info
    struct UserInfo {
        EnumerableSet.UintSet userLockIds;
        uint256 totalStaked;
        uint256 stakedInBiggestTier;
        uint256 totalClaimed;
    }

    // Address => UserInfo
    mapping ( address => UserInfo ) private userInfo;

    // Maps a user to whether or not they can deposit on behalf of others
    mapping ( address => bool ) public canDepositForOthers;

    // Total Lock Ids
    EnumerableSet.UintSet private allLockIds;

    struct WhalePool {
        /** total tokens staked in the whale pool */
        uint256 totalShares;

        /** total rewards given to this tier thus far */
        uint256 totalRewards;

        /** list of lockIds currently locked in this tier */
        EnumerableSet.AddressSet allUsers;

        /** reward tracking data for this tier */
        uint256 rewardsPerShare;

        /** Minimum Entry To Access WhalePool */
        uint256 minEntry;

        /** Maps an address to a total excluded amount */
        mapping ( address => uint256 ) totalExcluded;
    }

    // Whale Pool
    WhalePool internal whalePool;

    // Total Shares
    uint256 public totalShares;

    // Num Tiers To Consider
    uint8 public constant NUM_TIERS = 3;

    // Lock Nonce
    uint256 public lockNonce;

    // Minimum Deposit
    uint256 public minDeposit = 1 ether;

    // Events
    event SetLockTime(uint LockTime);
    event SetEarlyFee(uint earlyFee);
    event SetFeeRecipient(address FeeRecipient);
    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(address token_, address feeRecipient_, address reward_) {
        require(
            token_ != address(0) &&
            feeRecipient_ != address(0) &&
            reward_ != address(0),
            'Zero Address'
        );
        token = token_;
        feeRecipient = feeRecipient_;
        reward = reward_;
        emit Transfer(address(0), msg.sender, 0);
    }

    /** Returns the total number of tokens in existence */
    function totalSupply() external view returns (uint256) { 
        return totalShares; 
    }

    /** Returns the number of tokens owned by `account` */
    function balanceOf(address account) public view returns (uint256) { 
        return userInfo[account].totalStaked;
    }
    
    /** Token Name */
    function name() public pure returns (string memory) {
        return _name;
    }

    /** Token Ticker Symbol */
    function symbol() public pure returns (string memory) {
        return _symbol;
    }

    /** Tokens decimals */
    function decimals() public pure returns (uint8) {
        return _decimals;
    }

    function setTierInfo(uint8 tier, uint256 lockTime, uint256 earlyFee) external onlyOwner {
        require(
            tier < NUM_TIERS,
            'Invalid Tier'
        );
        require(
            earlyFee < 1_000,
            'Invalid Early Fee'
        );
        require(
            lockTime < 730 days,
            'Invalid Lock Time'
        );

        tiers[tier].lockTime = lockTime;
        tiers[tier].leaveEarlyFee = earlyFee;
        emit SetLockTime(lockTime);
        emit SetEarlyFee(earlyFee);
    }

    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        require(
            newFeeRecipient != address(0),
            'Zero Address'
        );
        feeRecipient = newFeeRecipient;
        emit SetFeeRecipient(newFeeRecipient);
    }

    function setRewardToken(address reward_) external onlyOwner {
        require(
            reward_ != address(0),
            'Zero Address'
        );
        reward = reward_;
    }

    function withdrawForeignToken(address token_, address to, uint256 amount) external onlyOwner {
        require(
            token != token_,
            'Cannot Withdraw Staking Token'
        );
        require(
            IERC20(token_).transfer(
                to,
                amount
            ),
            'Failure On Token Withdraw'
        );
    }

    function setCanDepositForOthers(address user, bool canDeposit) external onlyOwner {
        canDepositForOthers[user] = canDeposit;
    }

    function setMinDeposit(uint256 newMinDeposit) external onlyOwner {
        minDeposit = newMinDeposit;
    }

    function batchClaim(address[] calldata users) external onlyOwner {
        uint len = users.length;
        for (uint256 i = 0; i < len;) {
            _claimReward(users[i]);
            unchecked { ++i; }
        }
    }

    function claimRewards() external {
        _claimReward(msg.sender);
    }

    function batchWithdraw(uint256[] calldata lockIds, uint256[] calldata amounts) external {
        uint len = lockIds.length;
        require(len == amounts.length, 'Invalid Input Length');

        // loop through ids, withdrawing from each
        for (uint256 i = 0; i < len;) {
            withdraw(lockIds[i], amounts[i]);
            unchecked { ++i; }
        }
    }

    function batchWithdrawAll(uint256[] calldata lockIds) external {
        uint len = lockIds.length;

        // loop through ids, withdrawing from each
        for (uint256 i = 0; i < len;) {
            uint256 amount = lockInfo[lockIds[i]].currentAmount;
            if (amount > 0) {
                withdraw(lockIds[i], amount);
            }
            unchecked { ++i; }
        }
    }

    function withdraw(uint256 lockId, uint256 amount) public {
        require(
            lockId < lockNonce,
            'Invalid Lock Id'
        );

        // fetch remaining lock amount
        uint256 remainingAmount = lockInfo[lockId].currentAmount;
        uint8 tier = lockInfo[lockId].tier;
        uint256 previousTotalStaked = userInfo[msg.sender].totalStaked;
        require(
            remainingAmount > 0,
            'Zero Tokens Remain Locked'
        );
        require(
            amount <= remainingAmount,
            'Insufficient Lock Balance'
        );
        require(
            amount > 0,
            'Zero Amount'
        );
        require(
            msg.sender == lockInfo[lockId].user,
            'Invalid User'
        );

        if (userInfo[msg.sender].totalStaked > 0) {
            _claimReward(msg.sender);
        }

        // reduce data from each tier before and including the current tier
        for (uint8 i = 0; i <= tier;) {
            tiers[i].tierStaked[msg.sender] -= amount;
            tiers[i].totalShares -= amount;
            unchecked { ++i; }
        }

        // reduce user data
        userInfo[msg.sender].totalStaked -= amount;

        // reduce global data
        totalShares -= amount;

        // reduce total staked in biggest tier if applicable
        if (tier == NUM_TIERS - 1)  {
            userInfo[msg.sender].stakedInBiggestTier -= amount;
        }
        
        // reduce lock data
        lockInfo[lockId].currentAmount -= amount;

        // if all tokens for lock withdrawn, remove from tracking
        if (lockInfo[lockId].currentAmount == 0) {
            EnumerableSet.remove(userInfo[msg.sender].userLockIds, lockId);
            EnumerableSet.remove(allLockIds, lockId);
        }

        // loop through each tier, determining rewards and updating excluded state
        for (uint8 i = 0; i < NUM_TIERS;) {

            // update total excluded
            tiers[i].totalExcluded[msg.sender] = getCumulativeDividends(tiers[i].tierStaked[msg.sender], i);

            // increment loop
            unchecked { ++i; }
        }

        // manage whale pool if applicable
        if (isInWhalePool(msg.sender)) {

            // user is no longer in whale pool
            if (userInfo[msg.sender].stakedInBiggestTier < whalePool.minEntry) {
                
                // remove user from pool
                EnumerableSet.remove(whalePool.allUsers, msg.sender);

                // subtract the user's full balance from whale pool
                unchecked {
                    whalePool.totalShares -= previousTotalStaked;
                }
                
            // user still has enough tokens to be in whale pool
            } else {
                
                // subtract removed balance from whale pool
                unchecked {
                    whalePool.totalShares -= amount;
                }

            }

            // update total excluded
            whalePool.totalExcluded[msg.sender] = getCumulativeDividendsWhale(userInfo[msg.sender].totalStaked);
        }

        // determine leave early fee
        uint fee = timeUntilUnlock(lockId) == 0 ? 0 : ( amount * tiers[tier].leaveEarlyFee ) / 1_000;

        // if there is a leave early fee, take it
        if (fee > 0) {
            IERC20(token).approve(feeRecipient, fee);
            IFeeRecipient(feeRecipient).takeFee(fee, tier);
        }

        // reduce fee from amount to send
        uint sendAmount = amount - fee;

        // transfer tokens to sender
        require(
            IERC20(token).transfer(msg.sender, sendAmount),
            'Failure On Token Transfer To Sender'
        );

        // emit event for bscscan tracker
        emit Transfer(msg.sender, address(0), amount);
    }

    function stake(address user, uint256 amount, uint8 tier) external {
        require(
            tier < NUM_TIERS,
            'Invalid Tier'
        );
        require(
            amount >= minDeposit,
            'Zero Amount'
        );
        if (user != msg.sender) {
            require(
                canDepositForOthers[msg.sender],
                'Cannot Deposit For Others'
            );
        }

        // if tokens are held, claim any pending rewards
        if (userInfo[user].totalStaked > 0) {
            _claimReward(user);
        }

        // transfer in tokens
        uint received = _transferIn(token, amount);

        // loop through earlier tiers and add to totalShares and tierStaked so user gets rewards from all below tiers as well
        for (uint8 i = 0; i <= tier;) {
            unchecked {
                tiers[i].tierStaked[user] += received;
                tiers[i].totalShares += received;
                ++i;
            }
        }

        // update other data
        unchecked {
            // add user total staked data
            userInfo[user].totalStaked += received;

            // add global data
            totalShares += received;
        }

        // add tracking for biggest tier if staked in highest tier, for whale pool
        if (tier == NUM_TIERS - 1)  {
            unchecked {
                userInfo[user].stakedInBiggestTier += received;
            }
        }

        // track lockId
        EnumerableSet.add(userInfo[user].userLockIds, lockNonce);
        EnumerableSet.add(allLockIds, lockNonce);

        // set lock data
        lockInfo[lockNonce] = LockId({
            user: user,
            totalLocked: received,
            currentAmount: received,
            unlockTime: block.timestamp + tiers[tier].lockTime,
            tier: tier
        });

        // increment lock nonce
        unchecked { ++lockNonce; }

        // loop through each tier, determining rewards and updating excluded state
        for (uint8 i = 0; i < NUM_TIERS;) {

            // update total excluded
            tiers[i].totalExcluded[user] = getCumulativeDividends(tiers[i].tierStaked[user], i);

            // increment loop
            unchecked { ++i; }
        }

        // if user has access to whale pool
        if (userInfo[user].stakedInBiggestTier >= whalePool.minEntry) {

            // if user is in whale pool
            if (isInWhalePool(user)) {
                
                // user is already in whale pool, update the total shares of the pool
                unchecked {
                    whalePool.totalShares += received;
                }

            // if user is not in whale pool
            } else {

                // user is not in whale pool, add them into the list
                EnumerableSet.add(whalePool.allUsers, user);

                // add their entire stake amount to the whale pools total shares
                unchecked {
                    whalePool.totalShares += userInfo[user].totalStaked;
                }
            }

            // update total excluded
            whalePool.totalExcluded[user] = getCumulativeDividendsWhale(userInfo[user].totalStaked);
        }

        // emit transfer
        emit Transfer(address(0), user, received);
    }

    function depositRewards(uint256 amount, uint8 tier) external {
        if (amount == 0) {
            return;
        }

        if (tier >= NUM_TIERS) {

            // WHALE POOL, Ensure shares exist
            if (whalePool.totalShares == 0) {
                return;
            }

            // transfer in reward token
            uint received = _transferIn(reward, amount);

            // update state
            unchecked {
                whalePool.rewardsPerShare += ( received * precision ) / whalePool.totalShares;
                whalePool.totalRewards += received;
            }

        } else {
            
            // ensure shares exist to gain rewards
            if (tiers[tier].totalShares == 0) {
                return;
            }

            // transfer in reward token
            uint received = _transferIn(reward, amount);

            // update state
            unchecked {
                tiers[tier].rewardsPerShare += ( received * precision ) / tiers[tier].totalShares;
                tiers[tier].totalRewards += received;
            }
        }
    }


    function _claimReward(address user) internal {

        // exit if zero value locked
        if (userInfo[user].totalStaked == 0) {
            return;
        }

        // total rewards to claim
        uint256 totalRewards = 0;

        // loop through each tier, determining rewards and updating excluded state
        for (uint8 i = 0; i < NUM_TIERS;) {

            // fetch pending rewards for tier
            totalRewards += pendingRewardsPerTier(user, i);

            // update total excluded
            tiers[i].totalExcluded[user] = getCumulativeDividends(tiers[i].tierStaked[user], i);

            // increment loop
            unchecked { ++i; }
        }

        // if user is in whale tier, claim rewards
        if (isInWhalePool(user)) {
            totalRewards += pendingRewardsWhalePool(user);
            whalePool.totalExcluded[user] = getCumulativeDividendsWhale(userInfo[user].totalStaked);
        }

        // clamp to available balance in case of migration or round error
        uint256 availableBalance = IERC20(reward).balanceOf(address(this));
        if (totalRewards > availableBalance) {
            totalRewards = availableBalance;
        }

        // transfer reward to user if rewards exist
        if (totalRewards > 0) {
            IERC20(reward).transfer(user, totalRewards);
        }
    }

    function _transferIn(address _token, uint256 amount) internal returns (uint256) {
        require(
            IERC20(_token).balanceOf(msg.sender) >= amount,
            'Insufficient Balance'
        );
        require(
            IERC20(_token).allowance(msg.sender, address(this)) >= amount,
            'Insufficient Allowance'
        );

        // transfer in, noting balance changes
        uint before = IERC20(_token).balanceOf(address(this));
        IERC20(_token).transferFrom(msg.sender, address(this), amount);
        uint After = IERC20(_token).balanceOf(address(this));
        require(
            After > before,
            'Error On TransferIn'
        );

        // return balance change
        return After - before;
    }


    function getTierInfo(uint8 tier) external view returns (uint256, uint256, uint256, uint256, uint256) {
        return (
            tiers[tier].totalShares,
            tiers[tier].totalRewards,
            tiers[tier].rewardsPerShare,
            tiers[tier].lockTime,
            tiers[tier].leaveEarlyFee
        );
    }

    function listLockIdsForUser(address user) external view returns (uint256[] memory) {
        return EnumerableSet.values(userInfo[user].userLockIds);
    }

    function viewAllLockIds() external view returns (uint256[] memory) {
        return EnumerableSet.values(allLockIds);
    }

    function paginateAllLockIds(uint256 startIndex, uint256 endIndex) external view returns (uint256[] memory) {
        uint256[] memory result = new uint256[](endIndex - startIndex);
        for (uint256 i = startIndex; i < endIndex; i++) {
            result[i - startIndex] = EnumerableSet.at(allLockIds, i);
        }
        return result;
    }

    function getLockInfo(uint256 lockId) external view returns (address user, uint256 totalLocked, uint256 currentAmount, uint256 unlockTime, uint8 tier) {
        return (
            lockInfo[lockId].user,
            lockInfo[lockId].totalLocked,
            lockInfo[lockId].currentAmount,
            lockInfo[lockId].unlockTime,
            lockInfo[lockId].tier
        );
    }

    function batchLockInfo(uint256[] calldata lockIDs) external view returns (LockId[] memory) {
        LockId[] memory result = new LockId[](lockIDs.length);
        for (uint256 i = 0; i < lockIDs.length; i++) {
            result[i] = lockInfo[lockIDs[i]];
        }
        return result;
    }

    function getLockInfoByUser(address user) external view returns (LockId[] memory) {
        uint len = EnumerableSet.length(userInfo[user].userLockIds);
        LockId[] memory result = new LockId[](len);
        for (uint256 i = 0; i < len; i++) {
            result[i] = lockInfo[EnumerableSet.at(userInfo[user].userLockIds, i)];
        }
        return result;
    }

    function getUserInfo(address user) external view returns (
        uint256[] memory,
        uint256[] memory,
        uint256[] memory,
        uint8[] memory,
        uint256,
        uint256,
        uint256
    ) {
        address _user = user;
        uint len = EnumerableSet.length(userInfo[_user].userLockIds);
        uint256[] memory totalLockeds = new uint256[](len);
        uint256[] memory currentAmounts = new uint256[](len);
        uint256[] memory timeLocks = new uint256[](len);
        uint8[] memory userTiers = new uint8[](len);
        for (uint256 i = 0; i < len; i++) {
            uint256 lockId = EnumerableSet.at(userInfo[_user].userLockIds, i);
            totalLockeds[i] = lockInfo[lockId].totalLocked;
            currentAmounts[i] = lockInfo[lockId].currentAmount;
            timeLocks[i] = timeUntilUnlock(lockId);
            userTiers[i] = lockInfo[lockId].tier;
        }
        return (totalLockeds, currentAmounts, timeLocks, userTiers, userInfo[_user].totalStaked, userInfo[_user].totalClaimed, pendingRewards(_user));
    }

    function userStakedInTier(address user, uint8 tier) external view returns (uint256) {
        return tiers[tier].tierStaked[user];
    }

    function userBatchStakedInTier(address user, uint8[] calldata _tiers) external view returns (uint256[] memory) {
        uint256[] memory result = new uint256[](_tiers.length);
        for (uint8 i = 0; i < _tiers.length; i++) {
            result[i] = tiers[_tiers[i]].tierStaked[user];
        }
        return result;
    }

    function getAllWhalePoolUsers() external view returns (address[] memory) {
        return EnumerableSet.values(whalePool.allUsers);
    }

    function isInWhalePool(address user) public view returns (bool) {
        return EnumerableSet.contains(whalePool.allUsers, user);
    }

    function getWhalePoolData() external view returns (uint256, uint256, uint256, uint256) {
        return (
            whalePool.totalShares,
            whalePool.totalRewards,
            whalePool.rewardsPerShare,
            whalePool.minEntry
        );
    }

    function timeUntilUnlock(uint256 lockId) public view returns (uint256) {
        return lockInfo[lockId].unlockTime < block.timestamp ? 0 : lockInfo[lockId].unlockTime - block.timestamp;
    }

    function pendingRewards(address user) public view returns (uint256 totalRewards) {
        if(userInfo[user].totalStaked == 0){ return 0; }

        for (uint8 i = 0; i < NUM_TIERS;) {
            unchecked {
                totalRewards += pendingRewardsPerTier(user, i);
            }
            unchecked { ++i; }
        }

        if (isInWhalePool(user)) {
            totalRewards += pendingRewardsWhalePool(user);
        }
    }

    function pendingRewardsPerTier(address user, uint8 tier) public view returns (uint256) {
        
        // get tier balance
        uint256 tierBalance = tiers[tier].tierStaked[user];
        if (tierBalance == 0) {
            return 0;
        }

        uint256 totalDividends = getCumulativeDividends(tierBalance, tier);
        uint256 tExcluded = tiers[tier].totalExcluded[user];

        if(totalDividends <= tExcluded){ return 0; }

        return totalDividends <= tExcluded ? 0 : totalDividends - tExcluded;
    }

    function pendingRewardsWhalePool(address user) public view returns (uint256) {
        
        // get tier balance
        uint256 tierBalance = userInfo[user].totalStaked;
        if (tierBalance == 0 || isInWhalePool(user) == false) {
            return 0;
        }

        uint256 totalDividends = getCumulativeDividendsWhale(tierBalance);
        uint256 tExcluded = whalePool.totalExcluded[user];

        if(totalDividends <= tExcluded){ return 0; }

        return totalDividends <= tExcluded ? 0 : totalDividends - tExcluded;
    }

    function getCumulativeDividends(uint256 share, uint8 tier) internal view returns (uint256) {
        return ( share * tiers[tier].rewardsPerShare ) / precision;
    }

    function getCumulativeDividendsWhale(uint256 share) internal view returns (uint256) {
        return ( share * whalePool.rewardsPerShare ) / precision;
    }

    receive() external payable {}

}