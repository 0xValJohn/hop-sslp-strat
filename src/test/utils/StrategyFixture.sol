// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.12;
pragma abicoder v2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ExtendedTest} from "./ExtendedTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVault} from "../../interfaces/Vault.sol";
import "../../interfaces/Hop/ISwap.sol";

// NOTE: if the name of the strat or file changes this needs to be updated
import {Strategy} from "../../Strategy.sol";

// Artifact paths for deploying from the deps folder, assumes that the command is run from
// the project root.
string constant vaultArtifact = "artifacts/Vault.json";

// Base fixture deploying Vault
contract StrategyFixture is ExtendedTest {
    using SafeERC20 for IERC20;

    struct AssetFixture { // To test multiple assets
        IVault vault;
        Strategy strategy;
        IERC20 want;
    }

    IERC20 public weth;

    AssetFixture[] public assetFixtures;

    mapping(string => address) public tokenAddrs;
    mapping(string => uint256) public tokenPrices;
    mapping(string => uint256) public saddleSwapAddrs;
    mapping(string => uint256) public saddleLpTokenAddrs;

    address public gov = 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52;
    address public user = address(1);
    address public whale = address(2);
    address public rewards = address(3);
    address public guardian = address(4);
    address public management = address(5);
    address public strategist = address(6);
    address public keeper = address(7);

    uint256 public minFuzzAmt = 1 ether; // 10 cents
    // @dev maximum amount of want tokens deposited based on @maxDollarNotional
    uint256 public maxFuzzAmt = 25_000_000 ether; // $25M
    // Used for integer approximation
    uint256 public constant DELTA = 10**4;

    function setUp() public virtual {
        _setTokenPrices();
        _setTokenAddrs();
        _setSaddleSwapAddrs();
        _setSaddleLpTokenAddrs();

        weth = IERC20(tokenAddrs["WETH"]);

        string[2] memory _tokensToTest = ["WETH", "DAI", "USDT", "USDC"];

        for (uint8 i = 0; i < _tokensToTest.length; ++i) {
            string memory _tokenToTest = _tokensToTest[i];
            IERC20 _want = IERC20(tokenAddrs[_tokenToTest]);

            (address _vault, address _strategy) = deployVaultAndStrategy(
                address(_want),
                _tokenToTest,
                gov,
                rewards,
                "",
                "",
                guardian,
                management,
                keeper,
                strategist
            );

            assetFixtures.push(AssetFixture(IVault(_vault), Strategy(_strategy), _want));

            vm.label(address(_vault), string(abi.encodePacked(_tokenToTest, "Vault")));
            vm.label(address(_strategy), string(abi.encodePacked(_tokenToTest, "Strategy")));
            vm.label(address(_want), _tokenToTest);
        }

        // add more labels to make your traces readable
        vm.label(gov, "Gov");
        vm.label(user, "User");
        vm.label(whale, "Whale");
        vm.label(rewards, "Rewards");
        vm.label(guardian, "Guardian");
        vm.label(management, "Management");
        vm.label(strategist, "Strategist");
        vm.label(keeper, "Keeper");
    }

    // Deploys a vault
    function deployVault(
        address _token,
        address _gov,
        address _rewards,
        string memory _name,
        string memory _symbol,
        address _guardian,
        address _management
    ) public returns (address) {
        vm.prank(_gov);
        address _vaultAddress = deployCode(vaultArtifact);
        IVault _vault = IVault(_vaultAddress);

        vm.prank(_gov);
        _vault.initialize(
            _token,
            _gov,
            _rewards,
            _name,
            _symbol,
            _guardian,
            _management
        );

        vm.prank(_gov);
        _vault.setDepositLimit(type(uint256).max);

        return address(_vault);
    }

    // Deploys a strategy
    function deployStrategy(
        address _vault,
        string memory _tokenSymbol
    ) public returns (address) {
        Strategy _strategy = new Strategy(
            _vault, 
            saddleSwapAddrs[_tokenSymbol], 
            saddleLpTokenAddrs[_tokenSymbol]
        );

        return address(_strategy);
    }

    // Deploys a vault and strategy attached to vault
    function deployVaultAndStrategy(
        address _token,
        string memory _tokenSymbol,
        address _gov,
        address _rewards,
        string memory _name,
        string memory _symbol,
        address _guardian,
        address _management,
        address _keeper,
        address _strategist
    ) public returns (address _vaultAddr, address _strategyAddr) {
        _vaultAddr = deployVault(
            _token,
            _gov,
            _rewards,
            _name,
            _symbol,
            _guardian,
            _management
        );
        IVault _vault = IVault(_vaultAddr);

        vm.prank(_strategist);
        _strategyAddr = deployStrategy(
            _vaultAddr,
            _tokenSymbol
        );
        Strategy _strategy = Strategy(_strategyAddr);

        vm.prank(_strategist);
        _strategy.setKeeper(_keeper);

        vm.prank(_gov);
        _vault.addStrategy(_strategyAddr, 10_000, 0, type(uint256).max, 1_000);

        return (address(_vault), address(_strategy));
    }

    function _setTokenAddrs() internal {
        tokenAddrs["WETH"] = 0x82af49447d8a07e3bd95bd0d56f35241523fbab1;
        tokenAddrs["USDT"] = 0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9;
        tokenAddrs["DAI"] = 0xda10009cbd5d07dd0cecc66161fc93d7c9000da1;
        tokenAddrs["USDC"] = 0xff970a61a04b1ca14834a43f5de4533ebddb5cc8;
    }

    function _setSaddleSwapAddrs() internal {
        saddleSwapAddrs["WETH"] = 0x652d27c0F72771Ce5C76fd400edD61B406Ac6D97;
        saddleSwapAddrs["USDT"] = 0x18f7402B673Ba6Fb5EA4B95768aABb8aaD7ef18a;
        saddleSwapAddrs["DAI"] = 0xa5A33aB9063395A90CCbEa2D86a62EcCf27B5742;
        saddleSwapAddrs["USDC"] = 0x10541b07d8Ad2647Dc6cD67abd4c03575dade261;
    }

    function _setSaddleLpTokenAddrs() internal {
        saddleLpTokenAddrs["WETH"] = 0x59745774Ed5EfF903e615F5A2282Cae03484985a;
        saddleLpTokenAddrs["USDT"] = 0xCe3B19D820CB8B9ae370E423B0a329c4314335fE;
        saddleLpTokenAddrs["DAI"] = 0x68f5d998F00bB2460511021741D098c05721d8fF;
        saddleLpTokenAddrs["USDC"] = 0xB67c014FA700E69681a673876eb8BAFAA36BFf71;
    }

    function _setTokenPrices() internal {
        tokenPrices["WETH"] = 1_000;
        tokenPrices["USDT"] = 1;
        tokenPrices["USDC"] = 1;
        tokenPrices["DAI"] = 1;
    }

}