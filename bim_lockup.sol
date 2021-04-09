// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./library.sol";

/**
 * @dev Contract module which provides a basic access control mechanism, where
 * there is an account (an owner) that can be granted exclusive access to
 * specific functions.
 *
 * By default, the owner account will be the one that deploys the contract. This
 * can later be changed with {transferOwnership}.
 *
 * This module is used through inheritance. It will make available the modifier
 * `onlyOwner`, which can be applied to your functions to restrict their use to
 * the owner.
 */
contract Ownable is Context {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @dev Initializes the contract setting the deployer as the initial owner.
     */
    constructor () internal {
        address msgSender = _msgSender();
        _owner = msgSender;
        emit OwnershipTransferred(address(0), msgSender);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(_owner == _msgSender(), "Ownable: caller is not the owner");
        _;
    }

    /**
     * @dev Leaves the contract without owner. It will not be possible to call
     * `onlyOwner` functions anymore. Can only be called by the current owner.
     *
     * NOTE: Renouncing ownership will leave the contract without an owner,
     * thereby removing any functionality that is only available to the owner.
     */
    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

/**
 * @dev BIM Lockup contract
 */
contract BIMLockup is Ownable {
    using SafeMath for uint;
    using SafeERC20 for IBIMToken;

    uint256 constant DAY = 86400;
    uint256 constant WEEK = DAY * 7;
    uint256 constant MONTH = DAY * 30;
    
    IBIMToken public BIMContract;
    
    // @dev lockup assets deposits are grouped by week
    struct Round {
        mapping (address => uint256) balances;
        uint vestFrom;
    }
    
    /// @dev rounds indexing
    mapping (int256 => Round) public rounds;
    /// @dev a monotonic increasing index
    int256 public currentRound = 0;

    /// @dev lockup balance
    mapping (address => uint256) public balances;
    
    /// @dev total locked-up
    uint256 public totalLockedUp;
    
    constructor(IBIMToken bimContract) 
        public {
        BIMContract = bimContract;
        rounds[0].vestFrom = block.timestamp; // create an week already in vesting
    }

    /**
     * @dev function called before every user's interaction
     */
    function beforeBalanceChange() internal {
        // create a new weekly round for deposit if recent week ends.
        if (block.timestamp > rounds[currentRound].vestFrom) {
            currentRound++;
            // new week starts
            rounds[currentRound].vestFrom = rounds[currentRound-1].vestFrom + WEEK;
        }
        
        // settle the caller before any lockup balance changes
        settleStakerBIMReward(msg.sender);
    }
    
    /**
     * @dev function called after balance changes
     */
    function afterBalanceChange() internal {
        // update contract's BIM balance after deposit or withdraw
        _lastBIMBalance = BIMContract.balanceOf(address(this));
    }
    
    /**
     * @dev deposit BIM
     */
    function deposit(uint256 amount) external {
        beforeBalanceChange();
                
        // transfer BIM from msg.sender
        BIMContract.safeTransferFrom(msg.sender, address(this), amount);
        // group deposits in current week to avert unbounded gas consumption in withdraw
        rounds[currentRound].balances[msg.sender] += amount;
        // modify sender's balance
        balances[msg.sender] += amount;
        // sum up total locked BIMs
        totalLockedUp += amount;

        afterBalanceChange();
    }
        
    /**
     * @dev get current unlocked deposits
     */
    function checkUnlocked(address account) public view returns(uint256) {
        uint256 monthAgo = block.timestamp - MONTH;

        // this loop is bounded to 30days/7days by checking vestFrom
        uint256 lockedAmount;
        for (int256 i= currentRound; i>=0; i--) {
            if (rounds[i].vestFrom < monthAgo) {
                break;
            } else {
                lockedAmount += rounds[i].balances[account];
            }
        }
        
        return balances[account].sub(lockedAmount);
    }
    
    /**
     * @dev withdraw BIM previously(1 month ago) deposited
     */
    function withdraw() external {
        beforeBalanceChange();
                
        uint256 unlockedAmount = checkUnlocked(msg.sender);

        // modify
        balances[msg.sender] -= unlockedAmount;
        // sub total locked up
        totalLockedUp -= unlockedAmount;
        
        // transfer unlocked amount
        BIMContract.safeTransfer(msg.sender, unlockedAmount);
        
        afterBalanceChange();
    }

    /**
     * @dev BIM Rewarding
     * ----------------------------------------------------------------------------------
     */
     
    /// @dev bim reward balance
    mapping (address => uint256) internal _bimBalance;  
    /// @dev round index mapping to accumulate sharea.
    mapping (uint => uint) private _accBIMShares;
    /// @dev mark holders' highest settled round.
    mapping (address => uint) private _settledBIMRounds;
    /// @dev a monotonic increasing round index, STARTS FROM 1
    uint256 private _currentBIMRound = 1;
    // @dev last BIM reward block
    uint256 private _lastBIMRewardBlock = block.number;
    // @dev BIM rewards per block
    uint256 public BIMBlockReward = 0;
    /// @dev lastest contract's BIM balance
    uint256 private _lastBIMBalance;
    
    uint256 internal constant SHARE_MULTIPLIER = 1e18; // share multiplier to avert division underflow

    /**
     * @dev set BIM reward per height
     */
    function setBIMBlockReward(uint256 reward) external onlyOwner {
        // settle previous rewards round
        updateBIMRound();
        
        // set new block reward
        BIMBlockReward = reward;
    }
    
    /**
     * @dev claim bonus BIMs
     */
    function claimBIMReward() external {
        beforeBalanceChange();
        
        // BIM balance modification
        uint bims = _bimBalance[msg.sender];
        delete _bimBalance[msg.sender]; // zero balance
        
        // transfer BIM
        BIMContract.safeTransfer(msg.sender, bims);
        
        afterBalanceChange();
    }
    
    /**
     * @notice sum unclaimed rewards;
     */
    function checkBIMReward(address account) external view returns(uint256 bim) {
        // reward = settled + unsettled + newMined + balance diff
        uint lastSettledRound = _settledBIMRounds[account];
        uint unsettledShare = _accBIMShares[_currentBIMRound-1].sub(_accBIMShares[lastSettledRound]);
        
        // block rewards
        uint bimsToMint;
        if (BIMContract.maxSupply() < BIMContract.totalSupply()) {
            uint blocksToReward = block.number.sub(_lastBIMRewardBlock);
            bimsToMint = BIMBlockReward.mul(blocksToReward);
            uint remain = BIMContract.maxSupply().sub(BIMContract.totalSupply());
            if (remain < bimsToMint) {
                bimsToMint = remain;
            }
        }
        
        // penalty
        uint bimDiff = BIMContract.balanceOf(address(this)).sub(_lastBIMBalance);

        // new distributable share
        uint newShare;
        if (totalLockedUp > 0) {
            newShare = bimDiff.add(bimsToMint).mul(SHARE_MULTIPLIER)
                                                .div(totalLockedUp);
        }
        
        return _bimBalance[account] + (unsettledShare + newShare)
                                            .mul(balances[account])
                                            .div(SHARE_MULTIPLIER);  // remember to div by SHARE_MULTIPLIER;
    }
    
    /**
     * @dev settle a staker's BIM rewards
     */
    function settleStakerBIMReward(address account) internal {
        updateBIMRound();
        
         // settle this account
        uint lastSettledRound = _settledBIMRounds[account];
        uint newSettledRound = _currentBIMRound - 1;
        
        // round BIM
        uint roundBIM = _accBIMShares[newSettledRound].sub(_accBIMShares[lastSettledRound])
                                .mul(balances[account])
                                .div(SHARE_MULTIPLIER);  // remember to div by SHARE_MULTIPLIER    
        
        // update BIM balance
        _bimBalance[account] += roundBIM;
        
        // mark new settled BIM round
        _settledBIMRounds[account] = newSettledRound;
    }
    
    /**
     * @dev update accumulated BIM block reward until current block, and also penalty received
     */
    function updateBIMRound() internal {
        // postpone BIM rewarding if there is none locked-up
        if (totalLockedUp == 0) {
            return;
        }
        
        // mint if BIMContract is mintable
        if (BIMContract.maxSupply() > BIMContract.totalSupply()) {
            // mint BIM for (_lastRewardBlock, block.number]
            uint blocksToReward = block.number.sub(_lastBIMRewardBlock);
            uint bimsToMint = BIMBlockReward.mul(blocksToReward);
            uint remain = BIMContract.maxSupply().sub(BIMContract.totalSupply());
            // cap to BIM max supply
            if (remain < bimsToMint) {
                bimsToMint = remain;
            }
            
            if (bimsToMint > 0) {
                // mint to this contract
                BIMContract.mint(address(this), bimsToMint);
            }
            
            // mark block rewarded;
            _lastBIMRewardBlock = block.number;
        }

        // compute BIM diff with _lastBIMBalance, this also re-distributes BIM-penalty received from:
        // BIMVesting Contract (early exit)
        uint bimDiff = BIMContract.balanceOf(address(this)).sub(_lastBIMBalance);
        if (bimDiff == 0) {
            return;
        }

        // BIM share
        uint roundBIMShare = bimDiff.mul(SHARE_MULTIPLIER)
                                    .div(totalLockedUp);
        
        // update contract's BIM balance
        _lastBIMBalance = BIMContract.balanceOf(address(this));
            
        // accumulate BIM share
        _accBIMShares[_currentBIMRound] = roundBIMShare.add(_accBIMShares[_currentBIMRound-1]); 
       
        // next round setting                                 
        _currentBIMRound++;
    }
}