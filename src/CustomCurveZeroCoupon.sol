// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract CustomCurveZeroCoupon is BaseHook, ERC1155Supply {
    using CurrencySettler for Currency;
    using SafeCast for int256;

    error AddLiquidityThroughHook();

    struct CallbackData {
        uint256 amountEach;
        Currency currency0;
        Currency currency1;
        address sender;
    }

    uint256 public constant LP_TOKEN_ID = 0; // Single token ID for LP tokens

    uint256 public maturityDate;
    uint256 public faceValue;
    uint256 public yieldRate; // For zero-coupon bonds

    uint256 public totalLiquidity0;
    uint256 public totalLiquidity1;

    constructor(IPoolManager poolManager) BaseHook(poolManager) ERC1155("") {}

    function initialize(
        uint256 _maturityDate,
        uint256 _faceValue,
        uint256 _yieldRate
    ) external {
        maturityDate = _maturityDate;
        faceValue = _faceValue;
        yieldRate = _yieldRate;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Disable adding liquidity through the PM
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert AddLiquidityThroughHook();
    }

    // Custom add liquidity function
    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        poolManager.unlock(
            abi.encode(
                CallbackData(
                    amountEach,
                    key.currency0,
                    key.currency1,
                    msg.sender
                )
            )
        );

        // Mint LP tokens to the sender
        _mint(msg.sender, LP_TOKEN_ID, amountEach, "");

        // Update total liquidity
        totalLiquidity0 += amountEach;
        totalLiquidity1 += amountEach;
    }

    function _unlockCallback(
        bytes calldata data
    ) internal override returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        callbackData.currency0.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false
        );
        callbackData.currency1.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false
        );

        callbackData.currency0.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true
        );
        callbackData.currency1.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true
        );

        return "";
    }

    function getExchangeRate() public view returns (uint256) {
        if (block.timestamp >= maturityDate) {
            return faceValue * 1e18; // Bond has matured, price is face value
        }
        uint256 timeToMaturity = maturityDate - block.timestamp;
        uint256 t = (timeToMaturity * 1e18) / 31536000; // Time in years scaled by 1e18
        uint256 r = yieldRate * 1e16; // Convert basis points to decimal scaled by 1e18

        uint256 denominator = 1e18 + (r * t) / 1e18;
        uint256 price = (faceValue * 1e36) / denominator;

        return price; // Scaled by 1e18
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 price = getExchangeRate();

        int256 specifiedAmount = params.amountSpecified;
        int256 unspecifiedAmount;

        if (params.zeroForOne) {
            if (params.amountSpecified < 0) {
                uint256 amountIn = uint256(-params.amountSpecified);
                uint256 amountOut = (amountIn * 1e18) / price;
                unspecifiedAmount = int256(amountOut);
            } else {
                uint256 amountOut = uint256(params.amountSpecified);
                uint256 amountIn = (amountOut * price) / 1e18;
                unspecifiedAmount = -int256(amountIn);
            }
        } else {
            if (params.amountSpecified < 0) {
                uint256 amountIn = uint256(-params.amountSpecified);
                uint256 amountOut = (amountIn * price) / 1e18;
                unspecifiedAmount = int256(amountOut);
            } else {
                uint256 amountOut = uint256(params.amountSpecified);
                uint256 amountIn = (amountOut * 1e18) / price;
                unspecifiedAmount = -int256(amountIn);
            }
        }

        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
            -specifiedAmount,
            unspecifiedAmount
        );

        if (params.zeroForOne) {
            if (params.amountSpecified < 0) {
                key.currency0.take(
                    poolManager,
                    address(this),
                    uint256(-params.amountSpecified),
                    true
                );
                key.currency1.settle(
                    poolManager,
                    address(this),
                    unspecifiedAmount.toUint256(),
                    true
                );
            } else {
                key.currency0.take(
                    poolManager,
                    address(this),
                    uint256(-unspecifiedAmount),
                    true
                );
                key.currency1.settle(
                    poolManager,
                    address(this),
                    uint256(params.amountSpecified),
                    true
                );
            }
        } else {
            if (params.amountSpecified < 0) {
                key.currency1.take(
                    poolManager,
                    address(this),
                    uint256(-params.amountSpecified),
                    true
                );
                key.currency0.settle(
                    poolManager,
                    address(this),
                    unspecifiedAmount.toUint256(),
                    true
                );
            } else {
                key.currency1.take(
                    poolManager,
                    address(this),
                    uint256(-unspecifiedAmount),
                    true
                );
                key.currency0.settle(
                    poolManager,
                    address(this),
                    uint256(params.amountSpecified),
                    true
                );
            }
        }

        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }

    // Remove Liquidity Function
    function removeLiquidity(PoolKey calldata key, uint256 lpTokenAmount) external {
        uint256 currentTotalSupply = totalSupply(LP_TOKEN_ID);
        require(currentTotalSupply > 0, "No liquidity");

        uint256 userBalance = balanceOf(msg.sender, LP_TOKEN_ID);
        require(userBalance >= lpTokenAmount, "Insufficient balance");

        // Calculate user's share in 1e18 precision
        uint256 share = (lpTokenAmount * 1e18) / currentTotalSupply;

        // Calculate amounts to withdraw
        uint256 currency0Amount = (totalLiquidity0 * share) / 1e18;
        uint256 currency1Amount = (totalLiquidity1 * share) / 1e18;

        // Update total liquidity
        totalLiquidity0 -= currency0Amount;
        totalLiquidity1 -= currency1Amount;

        // Burn LP tokens
        _burn(msg.sender, LP_TOKEN_ID, lpTokenAmount);

        // Burn claim tokens to get underlying tokens back
        key.currency0.settle(
            poolManager,
            address(this),
            currency0Amount,
            true // burn = true
        );
        key.currency1.settle(
            poolManager,
            address(this),
            currency1Amount,
            true // burn = true
        );

        // Transfer underlying tokens back to user
        key.currency0.settle(
            poolManager,
            msg.sender,
            currency0Amount,
            false // burn = false
        );
        key.currency1.settle(
            poolManager,
            msg.sender,
            currency1Amount,
            false // burn = false
        );
    }
}
