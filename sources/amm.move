// Module for UniswapV2 Automated Market Maker (AMM)
module amm::uniswapV2 {
    use 0x1::Account;
    use 0x1::CryptoHash;
    use 0x1::Event;
    use 0x1::Signer;
    use 0x1::U128;
    use 0x1::Vector;
    use std::cmp;
    use std::ascii;

    // Error Codes
    const ERROR_ZERO_INPUT: u64 = 0;
    const ERROR_INVALID_PAIR: u64 = 1;
    const ERROR_POOL_ALREADY_EXISTS: u64 = 2;
    const ERROR_EXCESSIVE_SLIPPAGE: u64 = 3;
    const ERROR_NO_LIQUIDITY: u64 = 4;

    // Constants
    const LP_FEE_BASE: u64 = 10000;

    // Math Functions

    // Performs multiplication and division, handling overflow/underflow
    public fun muldiv(a: u64, b: u64, c: u64): u64 {
        (((a as u128) * (b as u128)) / (c as u128)) as u64
    }

    // Performs ceil division for u128 arguments
    public fun ceil_div(a: u128, b: u128): u128 {
        if a == 0 {
            0
        } else {
            (a - 1) / b + 1
        }
    }

    // Event Definitions
    pub struct PoolCreated {
        pool_id: AccountAddress,
        token_a: TypeName,
        token_b: TypeName,
        initial_a: U128,
        initial_b: U128,
        lp_minted: U128,
    }

    pub struct LiquidityAdded {
        pool_id: AccountAddress,
        token_a: TypeName,
        token_b: TypeName,
        amountin_a: U128,
        amountin_b: U128,
        lp_minted: U128,
    }

    pub struct LiquidityRemoved {
        pool_id: AccountAddress,
        token_a: TypeName,
        token_b: TypeName,
        amountout_a: U128,
        amountout_b: U128,
        lp_burnt: U128,
    }

    pub struct Swapped {
        pool_id: AccountAddress,
        tokenin: TypeName,
        amountin: U128,
        tokenout: TypeName,
        amountout: U128,
    }

    // Pool and Factory Structs
    pub struct Pool<A, B> {
        id: AccountAddress,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
        lp_supply: Supply<LP<A, B>>,
        fee_points: U128,
    }

    pub struct Factory {
        id: AccountAddress,
        table: Vector<PoolItem>,
    }

    // PoolItem Struct
    pub struct PoolItem {
        token_a: TypeName,
        token_b: TypeName,
    }

    // Helper Functions

    // Add a new pool to the factory
    fun add_pool<A, B>(factory: &mut Factory) {
        let token_a = type_name::get::<A>();
        let token_b = type_name::get::<B>();
        assert cmp_type_names(&token_a, &token_b) == 0, ERROR_INVALID_PAIR;

        let item = PoolItem{ token_a, token_b };
        assert !table::exists(&factory.table, |x| x == item), ERROR_POOL_ALREADY_EXISTS;

        table::push_back(&mut factory.table, item)
    }

    // Compare type names function
    public fun cmp_type_names(a: &TypeName, b: &TypeName) -> bool {
        let bytes_a = ascii::as_bytes(type_name::borrow_string(a));
        let bytes_b = ascii::as_bytes(type_name::borrow_string(b));

        let len_a = vector::length(bytes_a);
        let len_b = vector::length(bytes_b);

        let mut i = 0;
        let n = cmp::min(len_a, len_b);
        while (i < n) {
            let a = *vector::borrow(bytes_a, i);
            let b = *vector::borrow(bytes_b, i);

            if (a < b) {
                return true;
            } else if (a > b) {
                return false;
            }
            i = i + 1;
        }

        len_a <= len_b
    }

    // Emit LiquidityAdded event
    fun emit_liquidity_added_event<A, B>(pool: &Pool<A, B>, amountin_a: U128, amountin_b: U128, lp_minted: U128) {
        Event::emit(LiquidityAdded {
            pool_id: pool.id,
            token_a: type_name::get::<A>(),
            token_b: type_name::get::<B>(),
            amountin_a,
            amountin_b,
            lp_minted,
        });
    }

    // Emit PoolCreated event
    fun emit_pool_created_event<A, B>(pool: &Pool<A, B>, initial_a: U128, initial_b: U128, lp_minted: U128) {
        Event::emit(PoolCreated {
            pool_id: pool.id,
            token_a: type_name::get::<A>(),
            token_b: type_name::get::<B>(),
            initial_a,
            initial_b,
            lp_minted,
        });
    }

    // Pool Balances Function
    public fun pool_balances<A, B>(pool: &Pool<A, B>) -> (U128, U128, U128) {
        (
            balance::value(&pool.balance_a),
            balance::value(&pool.balance_b),
            balance::supply_value(&pool.lp_supply)
        )
    }

    // Add Liquidity Function
    public fun add_liquidity<A, B>(pool: &mut Pool<A, B>, input_a: Balance<A>, input_b: Balance<B>, min_lp_out: U128) -> (Balance<A>, Balance<B>, Balance<LP<A, B>>) {
        assert!(balance::value(&input_a) > 0 && balance::value(&input_b) > 0, ERROR_ZERO_INPUT);

        // Calculate deposit amounts
        let (deposit_a, deposit_b, lp_to_issue) = calculate_deposits(pool, &input_a, &input_b);

        // Deposit amounts into pool 
        balance::join(&mut pool.balance_a, deposit_a);
        balance::join(&mut pool.balance_b, deposit_b);

        // Mint LP tokens
        assert!(lp_to_issue >= min_lp_out, ERROR_EXCESSIVE_SLIPPAGE);
        let lp = balance::increase_supply(&mut pool.lp_supply, lp_to_issue);

        emit_liquidity_added_event(pool, deposit_a, deposit_b, lp_to_issue);

        // Return amounts
        (balance::split(&mut input_a, deposit_a), balance::split(&mut input_b, deposit_b), lp)
    }

    // Calculate Deposits Function
    fun calculate_deposits<A, B>(pool: &Pool<A, B>, input_a: &Balance<A>, input_b: &Balance<B>) -> (U128, U128, U128) {
        // Calculate input amounts multiplied by pool balances
        let input_a_mul_pool_b: u128 = (balance::value(input_a) as u128) * (balance::value(&pool.balance_b) as u128);
        let input_b_mul_pool_a: u128 = (balance::value(input_b) as u128) * (balance::value(&pool.balance_a) as u128);

        // Calculate deposits and LP to issue
        let (deposit_a, deposit_b, lp_to_issue);
        if input_a_mul_pool_b > input_b_mul_pool_a {
            deposit_b = balance::value(input_b);
            deposit_a = ceil_div(input_b_mul_pool_a, balance::value(&pool.balance_b) as u128) as U128;
            lp_to_issue = muldiv(deposit_b, balance::supply_value(&pool.lp_supply), balance::value(&pool.balance_b));
        } else if input_a_mul_pool_b < input_b_mul_pool_a {
            deposit_a = balance::value(input_a);
            deposit_b = ceil_div(input_a_mul_pool_b, balance::value(&pool.balance_a) as u128) as U128;
            lp_to_issue = muldiv(deposit_a, balance::supply_value(&pool.lp_supply), balance::value(&pool.balance_a));
        } else {
            deposit_a = balance::value(input_a);
            deposit_b = balance::value(input_b);
            if balance::supply_value(&pool.lp_supply) == 0 {
                lp_to_issue = (deposit_a * deposit_b).sqrt();
            } else {
                lp_to_issue = muldiv(deposit_a, balance::supply_value(&pool.lp_supply), balance::value(&pool.balance_a));
            }
        }
        (deposit_a, deposit_b, lp_to_issue)
    }

    // Main logic for initialization
    fun init(ctx: &Signer) {
        let factory = Factory {
            id: ctx.address(),
            table: Vector::new(),
        };
        let mut signer = ctx;
        Event::emit(factory);
    }

    // Factory Function to Create Pool
    public fun create_pool<A, B>(factory: &mut Factory, init_a: Balance<A>, init_b: Balance<B>, ctx: &Signer) -> Balance<LP<A, B>> {
        assert!(balance::value(&init_a) > 0 && balance::value(&init_b) > 0, ERROR_ZERO_INPUT);

        add_pool(factory);

        // Create pool
        let mut pool = Pool {
            id: ctx.address(),
            balance_a: init_a,
            balance_b: init_b,
            lp_supply: Supply::new(),
            fee_points: LP_FEE_BASE,
        };

        let lp = balance::increase_supply(&mut pool.lp_supply, LP_FEE_BASE);

        emit_pool_created_event(&pool, balance::value(&init_a), balance::value(&init_b), LP_FEE_BASE);

        // Return LP tokens
        balance::new(lp)
    }

    // Get Pool ID Function
    public fun get_pool_id<A, B>(factory: &Factory) -> Option<AccountAddress> {
        let token_a = type_name::get::<A>();
        let token_b = type_name::get::<B>();

        table::find(&factory.table, |x| x.token_a == token_a && x.token_b == token_b).map(|x| x.id)
    }

    // Pool Exists Function
    public fun pool_exists<A, B>(factory: &Factory) -> bool {
        let token_a = type_name::get::<A>();
        let token_b = type_name::get::<B>();

        table::exists(&factory.table, |x| x.token_a == token_a && x.token_b == token_b)
    }

    // Add Liquidity to Pool Function
    public fun add_liquidity_to_pool<A, B>(factory: &Factory, pool_id: AccountAddress, input_a: Balance<A>, input_b: Balance<B>, min_lp_out: U128, ctx: &Signer) -> (Balance<A>, Balance<B>, Balance<LP<A, B>>) {
        assert!(balance::value(&input_a) > 0 && balance::value(&input_b) > 0, ERROR_ZERO_INPUT);

        let pool = load_pool(pool_id);

        // Perform add liquidity
        let (output_a, output_b, lp) = add_liquidity(&mut pool, input_a, input_b, min_lp_out);

        // Emit LiquidityAdded event
        emit_liquidity_added_event(&pool, output_a, output_b, lp);

        (output_a, output_b, lp)
    }

    // Load Pool Function
    fun load_pool<A, B>(pool_id: AccountAddress) -> Pool<A, B> {
        // Load pool from storage
        assert!(Account::exists(pool_id), ERROR_INVALID_PAIR);
        Account::load_mut<Pool<A, B>>(pool_id)
    }

    // Public function to add liquidity to a pool
    public fun add_liquidity<A, B>(input_a: Balance<A>, input_b: Balance<B>, min_lp_out: U128, ctx: &Signer) -> (Balance<A>, Balance<B>, Balance<LP<A, B>>) {
        assert!(balance::value(&input_a) > 0 && balance::value(&input_b) > 0, ERROR_ZERO_INPUT);

        let factory = Factory::load(ctx.address());
        assert!(pool_exists::<A, B>(&factory), ERROR_INVALID_PAIR);

        let pool_id = get_pool_id::<A, B>(&factory).unwrap();
        add_liquidity_to_pool(&factory, pool_id, input_a, input_b, min_lp_out, ctx)
    }

    // Function to handle token transfer or destruction
    fun destroy_zero_or_transfer_balance<T>(balance: &Balance<T>, receiver: AccountAddress, amount: u128) {
        if amount == 0 {
            balance::destroy(balance);
        } else {
            balance::transfer(balance, receiver, amount);
        }
    }

    // Remove Liquidity Function
    public fun remove_liquidity<A, B>(pool_id: AccountAddress, lp_to_burn: Balance<LP<A, B>>, min_a_out: Balance<A>, min_b_out: Balance<B>, ctx: &Signer) -> (Balance<A>, Balance<B>, Balance<LP<A, B>>) {
        let mut pool = load_pool(pool_id);

        // Check LP token balance
        assert!(balance::value(&lp_to_burn) > 0, ERROR_ZERO_INPUT);
        assert!(balance::supply_value(&pool.lp_supply) >= balance::value(&lp_to_burn), ERROR_NO_LIQUIDITY);

        // Calculate token amounts to return
        let (amount_a, amount_b) = calculate_burns(&mut pool, &lp_to_burn);

        // Transfer tokens back to the user
        destroy_zero_or_transfer_balance(&mut pool.balance_a, ctx.address(), amount_a);
        destroy_zero_or_transfer_balance(&mut pool.balance_b, ctx.address(), amount_b);

        // Burn LP tokens
        balance::destroy_supply(&mut pool.lp_supply, balance::value(&lp_to_burn));

        emit_liquidity_removed_event(&pool, amount_a, amount_b, lp_to_burn);

        (amount_a, amount_b, balance::new(0))
    }

    // Emit LiquidityRemoved event
    fun emit_liquidity_removed_event<A, B>(pool: &Pool<A, B>, amountout_a: U128, amountout_b: U128, lp_burnt: Balance<LP<A, B>>) {
        Event::emit(LiquidityRemoved {
            pool_id: pool.id,
            token_a: type_name::get::<A>(),
            token_b: type_name::get::<B>(),
            amountout_a,
            amountout_b,
            lp_burnt: balance::value(&lp_burnt),
        });
    }

    // Calculate Burns Function
    fun calculate_burns<A, B>(pool: &mut Pool<A, B>, lp_to_burn: &Balance<LP<A, B>>) -> (U128, U128) {
        let lp_to_burn_value = balance::value(lp_to_burn);
        let total_lp_supply = balance::supply_value(&pool.lp_supply);

        let amount_a = muldiv(balance::value(&pool.balance_a), lp_to_burn_value, total_lp_supply);
        let amount_b = muldiv(balance::value(&pool.balance_b), lp_to_burn_value, total_lp_supply);

        (amount_a, amount_b)
    }

    // Swap Function
    public fun swap<A, B>(pool_id: AccountAddress, token_in: TypeName, token_out: TypeName, amount_in: Balance<A>, min_amount_out: Balance<B>, ctx: &Signer) -> Balance<B> {
        let mut pool = load_pool(pool_id);

        // Ensure pool contains both tokens
        assert!(
            cmp_type_names(&token_in, &type_name::get::<A>()) || cmp_type_names(&token_in, &type_name::get::<B>()),
            ERROR_INVALID_PAIR
        );
        assert!(
            cmp_type_names(&token_out, &type_name::get::<A>()) || cmp_type_names(&token_out, &type_name::get::<B>()),
            ERROR_INVALID_PAIR
        );

        // Perform swap
        let amount_out = swap_internal(&mut pool, token_in, token_out, amount_in, min_amount_out, ctx);

        // Emit Swapped event
        emit_swapped_event(&pool, token_in, amount_in, token_out, amount_out);

        balance::new(amount_out)
    }

    // Internal Swap Function
    fun swap_internal<A, B>(pool: &mut Pool<A, B>, token_in: TypeName, token_out: TypeName, amount_in: Balance<A>, min_amount_out: Balance<B>, ctx: &Signer) -> U128 {
        let (amount_in_value, min_amount_out_value) = (balance::value(&amount_in), balance::value(&min_amount_out));

        let (reserve_in, reserve_out) = if cmp_type_names(&token_in, &type_name::get::<A>()) {
            (balance::value(&pool.balance_a), balance::value(&pool.balance_b))
        } else {
            (balance::value(&pool.balance_b), balance::value(&pool.balance_a))
        };

        assert!(reserve_in > 0 && reserve_out > 0, ERROR_NO_LIQUIDITY);

        let amount_in_with_fee = amount_in_value * (LP_FEE_BASE - balance::value(&pool.fee_points)) / LP_FEE_BASE;

        let amount_out = if cmp_type_names(&token_in, &type_name::get::<A>()) {
            let amount_out = muldiv(amount_in_with_fee, reserve_out, reserve_in + amount_in_with_fee);
            assert!(amount_out >= min_amount_out_value, ERROR_EXCESSIVE_SLIPPAGE);
            amount_out
        } else {
            let amount_out = muldiv(amount_in_with_fee, reserve_in, reserve_out + amount_in_with_fee);
            assert!(amount_out >= min_amount_out_value, ERROR_EXCESSIVE_SLIPPAGE);
            amount_out
        };

        if cmp_type_names(&token_in, &type_name::get::<A>()) {
            balance::transfer(&mut pool.balance_a, ctx.address(), amount_in_value);
            balance::destroy(&mut pool.balance_b);
        } else {
            balance::destroy(&mut pool.balance_a);
            balance::transfer(&mut pool.balance_b, ctx.address(), amount_in_value);
        }

        amount_out
    }

    // Emit Swapped event
    fun emit_swapped_event<A, B>(pool: &Pool<A, B>, token_in: TypeName, amount_in: Balance<A>, token_out: TypeName, amount_out: U128) {
        Event::emit(Swapped {
            pool_id: pool.id,
            tokenin: token_in,
            amountin: balance::value(&amount_in),
            tokenout: token_out,
            amountout,
        });
    }
}
