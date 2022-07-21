// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/Hop/ISwap.sol";

// This strategy needs to be generic & clonable

// WETH
// CanonicalToken = 0x82af49447d8a07e3bd95bd0d56f35241523fbab1
// SaddleLpToken = 0x59745774Ed5EfF903e615F5A2282Cae03484985a
// SaddleSwap = 0x652d27c0F72771Ce5C76fd400edD61B406Ac6D97

// DAI
// CanonicalToken = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1
// SaddleLpToken = 0x68f5d998F00bB2460511021741D098c05721d8fF
// SaddleSwap = 0xa5A33aB9063395A90CCbEa2D86a62EcCf27B5742

// USDC
// CanonicalToken = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8
// SaddleLpToken = 0xB67c014FA700E69681a673876eb8BAFAA36BFf71
// SaddleSwap = 0x10541b07d8Ad2647Dc6cD67abd4c03575dade261

// USDT
// CanonicalToken = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9
// SaddleLpToken = 0xCe3B19D820CB8B9ae370E423B0a329c4314335fE
// SaddleSwap = 0x18f7402B673Ba6Fb5EA4B95768aABb8aaD7ef18a

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // ---------------------- STATE VARIABLES ----------------------

    uint256 internal constant MAX_BIPS = 10_000;
    uint256 saddleLpToken;
    uint256 saddleSwap;
    uint256 maxSlippage;

    // ---------------------- CONSTRUCTOR ----------------------

    constructor(address _vault, address _saddleSwap, address _saddleLpToken)
        public
        BaseStrategy(_vault)
    {
        _initializeStrat();
    }

    function _initializeStrat() internal {
        maxSlippage = 30;
        saddleSwap = ISwap(_saddleSwap);
        saddleLpToken = IERC20(_saddleLpToken);
    }

    // ---------------------- CLONING ----------------------

    event Cloned(address indexed clone);

    bool public isOriginal = true;

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _maxSlippage,
        address _saddleSwap,
        address _saddleLpToken
    )
        external
    {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _maxSlippage = maxSlippage;
        _saddleSwap = saddleSwap;
        _saddleLpToken = saddleLpToken;
    }
    
    function cloneHopSSlp(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _maxSlippage,
        address _saddleSwap,
        address _saddleLpToken
    )
        external
        returns (address newStrategy)
    {
        require(isOriginal, "!clone");
        bytes20 addressBytes = bytes20(address(this));

        assembly {
                // EIP-1167 bytecode
                let clone_code := mload(0x40)
                mstore(
                    clone_code,
                    0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
                )
                mstore(add(clone_code, 0x14), addressBytes)
                mstore(
                    add(clone_code, 0x28),
                    0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
                )
                newStrategy := create(0, clone_code, 0x37)
            }

        Strategy(newStrategy).initialize(
                _vault,
                _strategist,
                _rewards,
                _keeper,
                _maxSlippage,
                _saddleSwap,
                _saddleLpToken
            );

        emit Cloned(newStrategy);
    }

    function name() external view override returns (string memory) {
        return
            string(
                abi.encodePacked(
                    "StrategyHopSSLp",
                    IERC20Metadata(address(want)).symbol()
                )
            );
    }

    // ---------------------- MAIN ----------------------

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant() + valueLpToWant();
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (uint256 _profit, uint256 _loss, uint256 _debtPayment)
    {
        uint256 _totalAssets = estimatedTotalAssets();
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;
        if (_totalAssets >= _totalDebt) {
            _profit = _totalAssets - _totalDebt;
            _loss = 0;
        } else {
            _loss = _totalDebt - _totalAssets;
            _profit = 0;
        }
        _debtPayment = _debtOutstanding;

        // free up _debtOutstanding + our profit, and make any necessary adjustments to the accounting.
        uint256 _liquidWant = balanceOfWant();
        uint256 _toFree = _debtOutstanding + _profit;

        // liquidate some of the Want
        if (_liquidWant < _toFree) {
            // liquidation can result in a profit depending on pool balance
            (uint256 _liquidationProfit, uint256 _liquidationLoss) =
                _removeliquidity(_toFree);

            // update the P&L to account for liquidation
            _loss = _loss + _liquidationLoss;
            _profit = _profit + _liquidationProfit;
            _liquidWant = balanceOfWant();

            // Case 1 - enough to pay profit (or some) only
            if (_liquidWant <= _profit) {
                _profit = _liquidWant;
                _debtPayment = 0;
            // Case 2 - enough to pay _profit and _debtOutstanding
            // Case 3 - enough to pay for all profit, and some _debtOutstanding
            } else {
                _debtPayment = Math.min(_liquidWant - _profit, _debtOutstanding);
            }
        }
        if (_loss > _profit) {
            _loss = _loss - _profit;
            _profit = 0;
        } else {
            _profit = _profit - _loss;
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _liquidWant = balanceOfWant(); 
        if (_liquidWant > _debtOutstanding) {
            uint256 _amountToInvest = _liquidWant - _debtOutstanding;
            _addLiquidity(_amountToInvest);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _liquidWant = balanceOfWant();
        if (_liquidWant < _amountNeeded) {
            _removeliquidity(_amountNeeded);
        } else {
            return (_amountNeeded, 0);
        }
        _liquidWant = balanceOfWant();
        if (_liquidWant >= _amountNeeded) {
            _liquidatedAmount = _amountNeeded;
        } else {
            _liquidatedAmount = _liquidWant;
            _loss = _amountNeeded - _liquidWant;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        _removeliquidity(_calculateRemoveLiquidityOneToken(saddleLpToken.balanceOf(address(this))));
        return want.balanceOf(address(this));
    }

    function prepareMigration(address _newStrategy) internal override {
    // nothing to do here, there is no non-want token!
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    // solhint-disable-next-line no-empty-blocks
    {}

    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        return _amtInWei;
    }

    // ---------------------- MANAGEMENT FUNCTIONS ----------------------

    function setMaxSlippage(uint256 _maxSlippage)
        external
        onlyVaultManagers
    {
        maxSlippage = _maxSlippage;
    }

    // ---------------------- HELPER AND UTILITY FUNCTIONS ----------------------

    // To deposit to Hop, we need to create an array of uints that tells Hop how much of each asset we want to deposit.
    // If we were to deposit 100 WETH e.g., we would pass [100, 0] (forget decimals for simplicity).
    // note: wtoken is always index 0

    function _addLiquidity(uint256 _wantAmount) internal {
        uint256 _minToMint = ISwap.calculateTokenAmount(address(this),[_wantAmount*maxSlippage, 0],1);
        uint256 _deadline = block.timestamp + 10 minutes;
        uint256 _priceImpact = (_minToMint * ISwap.getVirtualPrice() - _wantAmount) / _wantAmount * MAX_BIPS;
        if (_priceImpact > -maxSlippage) {
            return;
        } else {
            ISwap.addLiquidity([_wantAmount, 0], _minToMint, _deadline);
        }
    }

    function _removeliquidity(uint256 _wantAmount) internal {
        uint256 _minToMint = ISwap.calculateTokenAmount(address(this),[_wantAmount*maxSlippage, 0],0);
        uint256 _deadline = block.timestamp + 10 minutes;
        ISwap.removeLiquidityOneToken(_wantAmount, 0, _minToMint, _deadline);
    }

    function _calculateRemoveLiquidityOneToken(uint256 _lpTokenAmount)
        internal
    {
        return ISwap.calculateRemoveLiquidityOneToken(address(this), _lpTokenAmount, 0);
    }

    function valueLpToWant() public view returns (uint256) {
        uint256 _lpTokenAmount = saddleLpToken.balanceOf(address(this));
        return ISwap.calculateTokenAmount(address(this),[_lpTokenAmount, 0],0);
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }
}