
// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {
    BaseStrategy
} from "@yearnvaults/contracts/BaseStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

import "./interfaces/curve.sol";
import "./interfaces/yearn.sol";
import {IUniswapV2Router02} from "./interfaces/uniswap.sol";


contract StrategyCurveLINKVoterProxy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address private uniswapRouter = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address private sushiswapRouter = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;
    address public crvRouter = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F; // default to sushiswap

    address public constant crvLINKgauge = address(0xFD4D8a17df4C27c1dD245d153ccf4499e806C87D); // Curve LINK Gauge contract, v2 is tokenized, held by curveProxy
    address public voter = address(0xF147b8125d2ef93FB6965Db97D6746952a133934); // Yearn's veCRV voter

    address[] public crvPath;
    uint256 public keepCRV = 1000;
    uint256 public constant FEE_DENOMINATOR = 10000;
    bool public checkLiqGauge = true;

    ICurveFi public crvLINKpool = ICurveFi(address(0xF178C0b5Bb7e7aBF4e12A4838C7b7c5bA2C623c0)); // Curve LINK Pool
    ICurveStrategyProxy public curveProxy = ICurveStrategyProxy(address(0x9a165622a744C20E3B2CB443AeD98110a33a231b)); // Yearn's Updated v3 StrategyProxy
    ICrvV3 public crv = ICrvV3(address(0xD533a949740bb3306d119CC777fa900bA034cd52)); // 1e18
    IERC20 public link = IERC20(address(0x514910771AF9Ca656af840dff83E8264EcF986CA)); // 1e18 chainlink token
    IERC20 public weth = IERC20(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)); // 1e18

    constructor(address _vault) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;

        // want = crvLINK, Curve's LINK pool (LINK + sLINK)
        want.safeApprove(address(curveProxy), uint256(- 1));
        link.safeApprove(address(crvLINKpool), uint256(- 1));
        crv.approve(crvRouter, uint256(- 1));
        crv.approve(voter, uint256(- 1));

        // using all unwrapped tokens since there is a risk of insufficient funds for wrapped if swapping directly (sushiswap)
        crvPath = new address[](3);
        crvPath[0] = address(crv);
        crvPath[1] = address(weth);
        crvPath[2] = address(link);

    }

    function name() external override view returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyCurveLINKVoterProxy";
    }
    
    // total assets held by strategy
    function estimatedTotalAssets() public override view returns (uint256) {
        return curveProxy.balanceOf(crvLINKgauge).add(want.balanceOf(address(this)));
        
    }


    function prepareReturn(uint256 _debtOutstanding) internal override
    returns (
        uint256 _profit,
        uint256 _loss,
        uint256 _debtPayment
    ){
        // TODO: Do stuff here to free up any returns back into `want`
        // NOTE: Return `_profit` which is value generated by all positions, priced in `want`
        // NOTE: Should try to free up at least `_debtOutstanding` of underlying position

        uint256 gaugeTokens = curveProxy.balanceOf(crvLINKgauge);
        if(gaugeTokens > 0){
            curveProxy.harvest(crvLINKgauge);

            uint256 crvBalance = crv.balanceOf(address(this));
            uint256 _keepCRV = crvBalance.mul(keepCRV).div(FEE_DENOMINATOR);
            IERC20(crv).safeTransfer(voter, _keepCRV);
            curveProxy.lock();
            uint256 crvRemainder = crvBalance.sub(_keepCRV);
            
            _sell(crvRemainder);

 			uint256 linkBalance = link.balanceOf(address(this));
  			crvLINKpool.add_liquidity([linkBalance, 0], 0);
			
			
            _profit = want.balanceOf(address(this));
        }

        if (_debtOutstanding > 0) {
            uint256 stakedBal = curveProxy.balanceOf(crvLINKgauge);
            curveProxy.withdraw(crvLINKgauge, address(want), Math.min(stakedBal, _debtOutstanding));

            _debtPayment = Math.min(_debtOutstanding, want.balanceOf(address(this)));
        }
        return (_profit, _loss, _debtPayment);
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {

        //when migrated to we will sometimes have liquidity gauge balance. 
        //this should be withdrawn and added to proxy
        if(checkLiqGauge){
            uint256 liqGaugeBal = IGauge(crvLINKgauge).balanceOf(address(this));

            if(liqGaugeBal > 0){
                IGauge(crvLINKgauge).withdraw(liqGaugeBal);
            }

        }

        uint256 _toInvest = want.balanceOf(address(this));
        want.safeTransfer(address(curveProxy), _toInvest);
        curveProxy.deposit(crvLINKgauge, address(want));

    }

    function liquidatePosition(uint256 _amountNeeded) internal override returns (uint256 _liquidatedAmount, uint256 _loss){
        uint256 wantBal = want.balanceOf(address(this));
        uint256 stakedBal = curveProxy.balanceOf(crvLINKgauge);

        if (_amountNeeded > wantBal) {
            curveProxy.withdraw(crvLINKgauge, address(want), Math.min(stakedBal, _amountNeeded - wantBal));
        }

        _liquidatedAmount = Math.min(_amountNeeded, want.balanceOf(address(this)));
        return (_liquidatedAmount, _loss);
    }


    function _sell(uint256 _amount) internal {
        IUniswapV2Router02(crvRouter).swapExactTokensForTokens(_amount, uint256(0), crvPath, address(this), now.add(1800));
    }

    function prepareMigration(address _newStrategy) internal override {
        uint256 gaugeTokens = curveProxy.balanceOf(crvLINKgauge);
        if (gaugeTokens > 0) {
            curveProxy.withdraw(crvLINKgauge, address(want), gaugeTokens);
        }
    }

    function protectedTokens() internal view override returns (address[] memory) {
        address[] memory protected = new address[](1);
        protected[0] = crvLINKgauge;

        return protected;
    }
    
	// setter functions
	    
    function setProxy(address _proxy) external onlyGovernance {
        curveProxy = ICurveStrategyProxy(_proxy);
    }
    
    function updateCheckLiqGauge(bool _checkLiqGauge) external onlyAuthorized {
        checkLiqGauge = _checkLiqGauge;
    }
        
    function setKeepCRV(uint256 _keepCRV) external onlyGovernance {
        keepCRV = _keepCRV;
    }

    function setVoter(address _voter) external onlyGovernance {
        voter = _voter;
    }

    function setCrvRouter(bool isSushiswap) external onlyAuthorized {
        if (isSushiswap) {
            crvRouter = sushiswapRouter;
        } else {
            crvRouter = uniswapRouter;
        }
        
        crv.approve(crvRouter, uint256(- 1));
    }

}   
