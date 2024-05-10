module amm::uniswapv2 {
    use std::type_name::{Self, TypeName};
    use sui::balance::{Self, Balance, Supply};
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::math;
    use std::ascii;
    use sui::table::{Self, Table};
    use sui::tx_context::sender;
    use core::convert::TryInto;

    /* === errors === */

    enum Error {
        ZeroInput,
        InvalidPair,
        PoolAlreadyExists,
        ExcessiveSlippage,
        NoLiquidity,
        DivisionByZero,
    }

    /* === constants === */

    const LP_FEE_BASE: u64 = 10_000;

    /* === math === */

    /// Calculates (a * b) / c. Errors if result doesn't fit into u64.
    fun muldiv(a: u64, b: u64, c: u64): Result<u64, Error> {
        let mul_result = (a as u128).checked_mul(b as u128);
        let result = mul_result.and_then(|prod| prod.checked_div(c as u128));
        result.map(|value| value.try_into().unwrap_or(Err(Error::DivisionByZero)))
            .unwrap_or(Err(Error::DivisionByZero))
    }

    /// Calculates ceil_div((a * b), c). Errors if result doesn't fit into u64.
    fun ceil_muldiv(a: u64, b: u64, c: u64): Result<u64, Error> {
        let mul_result = (a as u128).checked_mul(b as u128);
        let result = mul_result.and_then(|prod| {
            let divisor = c as u128;
            let quotient = (prod + divisor - 1) / divisor;
            if quotient > u64::max_value() as u128 {
                None
            } else {
                Some(quotient as u64)
            }
        });
        result.map(|value| Ok(value))
            .unwrap_or(Err(Error::DivisionByZero))
    }

    /// Calculates sqrt(a * b).
    fun mulsqrt(a: u64, b: u64): Result<u64, Error> {
        let mul_result = (a as u128).checked_mul(b as u128);
        let result = mul_result.and_then(|prod| {
            let sqrt = prod.sqrt();
            if sqrt > u64::max_value() as u128 {
                None
            } else {
                Some(sqrt as u64)
            }
        });
        result.map(|value| Ok(value))
            .unwrap_or(Err(Error::DivisionByZero))
    }

    /* === events === */

    public struct PoolCreated has copy, drop {
        pool_id: ID,
        a: TypeName,
        b: TypeName,
        init_a: u64,
        init_b: u64,
        lp_minted: u64,
    }

    public struct LiquidityAdded has copy, drop {
        pool_id: ID,
        a: TypeName,
        b: TypeName,
        amountin_a: u64,
        amountin_b: u64,
        lp_minted: u64,
    }

    public struct LiquidityRemoved has copy, drop {
        pool_id: ID,
        a: TypeName,
        b: TypeName,
        amountout_a: u64,
        amountout_b: u64,
        lp_burnt: u64,
    }

    public struct Swapped has copy, drop {
        pool_id: ID,
        tokenin: TypeName,
        amountin: u64,
        tokenout: TypeName,
        amountout: u64,
    }

    /* === LP witness === */

    public struct LP<phantom A, phantom B> has drop {}

    /* === Pool === */

    public struct Pool<phantom A, phantom B> has key {
        id: UID,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
        lp_supply: Supply<LP<A, B>>,
        /// Fees for liquidity provider expressed in points (30 point is 0.3%)
        fee_points: u64,
    }

    public fun pool_balances<A, B>(pool: &Pool<A, B>): (u64, u64, u64) {
        (
            balance::value(&pool.balance_a),
            balance::value(&pool.balance_b),
            balance::supply_value(&pool.lp_supply)
        )
    }

    public fun pool_fees<A, B>(pool: &Pool<A, B>): u64 {
        pool.fee_points
    }

    /* === Factory === */

    public struct Factory has key {
        id: UID,
        table: Table<PoolItem, bool>,
    }

    public struct PoolItem has copy, drop, store  {
        a: TypeName,
        b: TypeName
    }

    fun add_pool<A, B>(factory: &mut Factory) -> Result<(), Error> {
        let a = type_name::get::<A>();
        let b = type_name::get::<B>();
        if cmp_type_names(&a, &b) != 0 {
            Err(Error::InvalidPair)
        } else {
            let item = PoolItem{ a, b };
            if table::contains(&factory.table, item) {
                Err(Error::PoolAlreadyExists)
            } else {
                table::add(&mut factory.table, item, true);
                Ok(())
            }
        }
    }

    // returns: 0 if a < b; 1 if a == b; 2 if a > b
    public fun cmp_type_names(a: &TypeName, b: &TypeName) -> u8 {
        let bytes_a = ascii::as_bytes(type_name::borrow_string(a));
        let bytes_b = ascii::as_bytes(type_name::borrow_string(b));

        let len_a = vector::length(bytes_a);
        let len_b = vector::length(bytes_b);

        let mut i = 0;
        let n = math::min(len_a, len_b);
        while i < n {
            let a = *vector::borrow(bytes_a, i);
            let b = *vector::borrow(bytes_b, i);
            if a < b {
                return 0
            } else if a > b {
                return 2
            }
            i += 1;
        };

        if len_a == len_b {
            1
        } else if len_a < len_b {
            0
        } else {
            2
        }
    }

    /* === main logic === */

    fun init(ctx: &mut TxContext) {
        let factory = Factory { 
            id: object::new(ctx),
            table: table::new(ctx),
        };
        transfer::share_object(factory);
    }

    pub fun create_pool<A, B>(factory: &mut Factory, init_a: Balance<A>, init_b: Balance<B>, ctx: &mut TxContext) -> Result<Balance<LP<A, B>>, Error> {
        if balance::value(&init_a) == 0 || balance::value(&init_b) == 0 {
            return Err(Error::ZeroInput);
        }

        let result = add_pool::<A, B>(factory).map(|_| {
            // create pool
            let mut pool = Pool::<A, B> {
                id: object::new(ctx),
                balance_a: init_a,
                balance_b: init_b,
                lp_supply: balance::create_supply(LP::<A, B> {}),
                fee_points: 30, // 0.3%
            };

            // mint initial lp tokens
            let lp_amount = mulsqrt(balance::value(&pool.balance_a), balance::value(&pool.balance_b))?;
            let lp_balance = balance::increase_supply(&mut pool.lp_supply, lp_amount)?;

            event::emit(PoolCreated {
                pool_id: object::id(&pool),
                a: type_name::
 get::(), b: type_name::get::(), init_a: balance::value(&pool.balance_a), init_b: balance::value(&pool.balance_b), lp_minted: lp_amount, });

 
        transfer::share_object(pool);
        Ok(lp_balance)
    });

    result.unwrap_or_else(|err| Err(err))
}

pub fun add_liquidity<A, B>(pool: &mut Pool<A, B>, mut input_a: Balance<A>, mut input_b: Balance<B>, min_lp_out: u64) -> Result<(Balance<A>, Balance<B>, Balance<LP<A, B>>), Error> {
    if balance::value(&input_a) == 0 || balance::value(&input_b) == 0 {
        return Err(Error::ZeroInput);
    }

    // calculate the deposit amounts
    let input_a_mul_pool_b = muldiv(balance::value(&input_a), balance::value(&pool.balance_b), u64::max_value())?;
    let input_b_mul_pool_a = muldiv(balance::value(&input_b), balance::value(&pool.balance_a), u64::max_value())?;

    let (deposit_a, deposit_b, lp_to_issue) = if input_a_mul_pool_b > input_b_mul_pool_a { // input_a / pool_a > input_b / pool_b
        let deposit_b = balance::value(&input_b);
        let deposit_a = ceil_div_u128(input_b_mul_pool_a, balance::value(&pool.balance_b) as u128)?;
        let lp_to_issue = muldiv(deposit_b, balance::supply_value(&pool.lp_supply), balance::value(&pool.balance_b))?;
        (deposit_a, deposit_b, lp_to_issue)
    } else if input_a_mul_pool_b < input_b_mul_pool_a { // input_a / pool_a < input_b / pool_b
        let deposit_a = balance::value(&input_a);
        let deposit_b = ceil_div_u128(input_a_mul_pool_b, balance::value(&pool.balance_a) as u128)?;
        let lp_to_issue = muldiv(deposit_a, balance::supply_value(&pool.lp_supply), balance::value(&pool.balance_a))?;
        (deposit_a, deposit_b, lp_to_issue)
    } else {
        let deposit_a = balance::value(&input_a);
        let deposit_b = balance::value(&input_b);
        let lp_to_issue = if balance::supply_value(&pool.lp
 _supply) == 0 { deposit_a // if there are no LP tokens in circulation, issue the same amount as input A } else { let lp_value = muldiv(balance::supply_value(&pool.lp_supply), balance::value(&pool.balance_a), balance::supply_value(&pool.balance_b))?; let new_lp_value = lp_value.checked_add(balance::value(&input_a)).ok_or(Error::ArithmeticOverflow)?; let new_lp_supply = balance::supply_from_value(new_lp_value)?; let lp_to_issue = new_lp_supply.checked_sub(balance::supply_value(&pool.lp_supply)).ok_or(Error::ArithmeticUnderflow)?; lp_to_issue }; (deposit_a, deposit_b, lp_to_issue) };

 
    // apply the deposit to the balances
    pool.balance_a = pool.balance_a.checked_add(deposit_a).ok_or(Error::ArithmeticOverflow)?;
    pool.balance_b = pool.balance_b.checked_add(deposit_b).ok_or(Error::ArithmeticOverflow)?;
    pool.lp_supply = balance::supply_from_value(balance::supply_value(&pool.lp_supply).checked_add(lp_to_issue).ok_or(Error::ArithmeticOverflow)?)?;

    if balance::supply_value(&pool.lp_supply) < min_lp_out {
        return Err(Error::InsufficientLiquidity);
    }

    // transfer tokens to the contract
    transfer::deposit_token(pool.token_a.as_ref().unwrap(), &mut input_a)?;
    transfer::deposit_token(pool.token_b.as_ref().unwrap(), &mut input_b)?;
    transfer::mint_lp(pool, lp_to_issue)?;

    Ok((input_a, input_b, balance::from_supply(lp_to_issue)))
}

pub fun remove_liquidity<A, B>(pool: &mut Pool<A, B>, lp_amount: Balance<LP<A, B>>, min_a_out: u64, min_b_out: u64) -> Result<(Balance<A>, Balance<B>), Error> {
    if balance::value(&lp_amount) == 0 {
        return Err(Error::ZeroInput);
    }

    let lp_supply_value = balance::supply_value(&pool.lp_supply);
    let lp_amount_value = balance::value(&lp_amount);
    let token_a_balance = transfer::balance_of(pool.token_a.as_ref().unwrap());
    let token_b_balance = transfer::balance_of(pool.token_b.as_ref().unwrap());

    let (exit_a, exit_b) = if lp_supply_value == lp_amount_value { // remove all liquidity and burn remaining LP tokens
        (pool.balance_a, pool.balance_b)
    } else {
        let lp_share = muldiv(lp_amount_value, lp_supply_value, balance::supply_value(&pool.lp_supply))?;
        let ratio_a = muldiv(lp_share, balance::value(&pool.balance_a), lp_supply_value)?;
        let ratio_b = muldiv(lp_share, balance::value(&pool.balance_b), lp_supply_value)?;

        // calculate the exit amounts
        let exit_a = balance::from_value(ratio_a)?;
        let exit_b = balance::from_value(ratio_b)?;

        pool.balance_a = pool.balance_a.checked_sub(ratio_a).ok_or(Error::ArithmeticUnderflow)?;
        pool.balance_b = pool.balance_b.checked_sub(ratio_b).ok_or(Error::ArithmeticUnderflow)?;
        (exit_a, exit_b)
    };

    if balance::value(&exit_a) < min_a_out || balance::value(&exit_b) < min_b_out {
        return Err(Error::InsufficientLiquidity);
    }

    transfer::burn_lp(pool, lp_amount_value)?;
    transfer::withdraw_token(pool.token_a.as_ref().unwrap(), balance::to_unsigned(exit_a))?;
    transfer::withdraw_token(pool.token_b.as_ref().unwrap(), balance::to_unsigned(exit_b))?;

    Ok((exit_a, exit_b))
}
 

}

#[cfg(test)] mod tests { use super::*;

 
#[test]
fn test_add_liquidity() {
    let token_a_balance = balance::to_unsigned(1000);
    let token_b_balance = balance::to_unsigned(5000);
    let mut pool = Pool::new(None, None, token_a_balance, token_b_balance).unwrap();

    let input_a = balance::to_unsigned(100);
    let input_b = balance::to_unsigned(200);

    let result = Pair::add_liquidity(&mut pool, input_a, input_b, 0);
    assert!(result.is_ok());

    let (output_a, output_b, lp) = result.unwrap();
    assert_eq!(output_a, balance::to_unsigned(100));
    assert_eq!(output_b, balance::to_unsigned(200));
    assert_eq!(balance::supply_value(&lp), 166);
    assert_eq!(balance::value(&pool.balance_a), 1100);
    assert_eq!(balance::value(&pool.balance_b), 5200);
    assert_eq!(balance::supply_value(&pool.lp_supply), 166);
}

#[test]
fn test_remove_liquidity() {
    let token_a_balance = balance::to_unsigned(1000);
    let token_b_balance = balance::to_unsigned(5000);
    let mut pool = Pool::new(None, None, token_a_balance, token_b_balance).unwrap();

    let input_a = balance::to_unsigned(100);
    let input_b = balance::to_unsigned(200);
    let result = Pair::add_liquidity(&mut pool, input_a, input_b, 0).unwrap();
    let (lp, _, _) = result;

    let result = Pair::remove_liquidity(&mut pool, lp, 0, 0);
    assert!(result.is_ok());

    let (output_a, output_b) = result.unwrap();
    assert_eq!(output_a, balance::to_unsigned(100));
    assert_eq!(output_b, balance::to_unsigned(200));
    assert_eq!(balance::value(&pool.balance_a), token_a_balance);
    assert_eq!(balance::value(&pool.balance_b), token_b_balance);
    assert_eq!(balance::supply_value(&pool.lp_supply), 0);
}
 

}cfg(test)] mod tests { use super::*;

 
#[test]
fn test_add_liquidity() {
    let token_a_balance = balance::to_unsigned(1000);
    let token_b_balance = balance::to_unsigned(5000);
    let mut pool = Pool::new(None, None, token_a_balance, token_b_balance).unwrap();

    let input_a = balance::to_unsigned(100);
    let input_b = balance::to_unsigned(200);

    let result = Pair::add_liquidity(&mut pool, input_a, input_b, 0);
    assert!(result.is_ok());

    let (output_a, output_b, lp) = result.unwrap();
    assert_eq!(output_a, balance::to_unsigned(100));
    assert_eq!(output_b, balance::to_unsigned(200));
    assert_eq!(balance::supply_value(&lp), 166);
    assert_eq!(balance::value(&pool.balance_a), 1100);
    assert_eq!(balance::value(&pool.balance_b), 5200);
    assert_eq!(balance::supply_value(&pool.lp_supply), 166);
}

#[test]
fn test_remove_liquidity() {
    let token_a_balance = balance::to_unsigned(1000);
    let token_b_balance = balance::to_unsigned(5000);
    let mut pool = Pool::new(None, None, token_a_balance, token_b_balance).unwrap();

    let input_a = balance::to_unsigned(100);
    let input_b = balance::to_unsigned(200);
    let result = Pair::add_liquidity(&mut pool, input_a, input_b, 0).unwrap();
    let (lp, _, _) = result;

    let result = Pair::remove_liquidity(&mut pool, lp, 0, 0);
    assert!(result.is_ok());

    let (output_a, output_b) = result.unwrap();
    assert_eq!(output_a, balance::to_unsigned(100));
    assert_eq!(output_b, balance::to_unsigned(200));
    assert_eq!(balance::value(&pool.balance_a), token_a_balance);
    assert_eq!(balance::value(&pool.balance_b), token_b_balance);
    assert_eq!(balance::supply_value(&pool.lp_supply), 0);
}

#[test]
fn test_swap_exact_a_for_b() {
    let token_a_balance = balance::to_unsigned(1000);
    let token_b_balance = balance::to_unsigned(5000);
    let mut pool = Pool::new(None, None, token_a_balance, token_b_balance).unwrap();

    let input_a = balance::to_unsigned(100);
    let result = Pair::swap_exact_a_for_b(&mut pool, input_a, 0).unwrap();

    let (output_b, input_a_used) = result;
    assert_eq!(output_b, balance::to_unsigned(168));
    assert_eq!(input_a_used, input_a);
    assert_eq!(balance::value(&pool.balance_a), 1100);
    assert_eq!(balance::value(&pool.balance_b), 5167);
}

#[test]
fn test_swap_exact_b_for_a() {
    let token_a_balance = balance::to_unsigned(1000);
    let token_b_balance = balance::to_unsigned(5000);
    let mut pool = Pool::new(None, None, token_a_balance, token_b_balance).unwrap();

    let input_b = balance::to_unsigned(500);
    let result = Pair::swap_exact_b_for_a(&mut pool, input_b, 0).unwrap();

    let (output_a, input_b_used) = result;
    assert_eq!(output_a, balance::to_unsigned(91));
    assert_eq!(input_b_used, input_b);
    assert_eq!(balance::value(&pool.balance_a), 1091);
    assert_eq!(balance::value(&pool.balance_b), 4500);
}
 

}
