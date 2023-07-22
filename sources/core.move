/*
    This quest involves the new standard of NFTs and requires knowledge of aptos-token-objects smart contract.
    The quest has two main features: breeding NFTs and combining NFTs.
    Breeding requires to have two monster NFTs from the same collection. It freezes transfer of those NFTs for time
    specified while creating a monster collection. After the time passed, owner of the two NFTs can call `hatch_monster`
    function, which unlocks the NFTs and transfers a new one with combine properties to the owner.
    Combining requires to have from 2 to 10 NFTs from the same collection (amount specified while creating equipment
    collection). Owner of the NFTs can call `combine_equipment` function to burn their NFTs and receive a new one with
    combined properties.
*/

module overmind::breeder_core {
    use std::bcs;
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_std::aptos_hash;
    use aptos_std::from_bcs;
    use aptos_std::math64;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::account::{Self, SignerCapability, new_event_handle};
    use aptos_framework::event::{Self, EventHandle, emit_event};
    use aptos_framework::object::{Self, Object, ungated_transfer_allowed};
    use aptos_framework::timestamp;
    use aptos_token_objects::aptos_token;
    use aptos_token_objects::token::{Self, Token};
    use aptos_token_objects::property_map::{Self, PropertyMap};
    use overmind::breeder_events::{Self, CreateDragonCollectionEvent, CreateDragonEvent, BreedDragonsEvent, HatchDragonEvent, CreateSwordCollectionEvent, CreateSwordEvent, CombineSwordsEvent, new_create_dragon_collection_event, new_create_dragon_event, new_create_sword_event, new_breed_dragons_event, new_hatch_dragon_event, new_combine_swords_event};
    #[test_only]
    use aptos_token_objects::collection;
    #[test_only]
    use aptos_token_objects::collection::Collection;
    #[test_only]
    use std::features;
    use aptos_token_objects::royalty;
    use std::option::Option;
    use aptos_token_objects::royalty::Royalty;

    ////////////
    // ERRORS //
    ////////////

    const ERROR_SIGNER_NOT_ADMIN: u64 = 0;
    const ERROR_STATE_NOT_INITIALIZED: u64 = 1;
    const ERROR_INVALID_BREEDING_TIME: u64 = 2;
    const ERROR_INVALID_COMBINE_AMOUNT: u64 = 3;
    const ERROR_INVALID_SWORDS_PROPERTY_VALUES_SUM: u64 = 4;
    const ERROR_COLLECTION_ALREADY_EXISTS: u64 = 5;
    const ERROR_COLLECTION_DOES_NOT_EXIST: u64 = 6;
    const ERROR_SIGNER_IS_NOT_THE_OWNER: u64 = 7;
    const ERROR_DRAGON_DURING_BREEDING: u64 = 8;
    const ERROR_DRAGONS_NOT_BREEDING: u64 = 9;
    const ERROR_BREEDING_HAS_NOT_ENDED: u64 = 10;
    const ERROR_INCORRECT_AMOUNT_OF_SWORDS: u64 = 11;
    const ERROR_PROPERTY_LENGTH_MISMATCH: u64 = 12;
    const ERROR_TOKEN_FROM_WRONG_COLLECTION: u64 = 13;

    //////////////
    // PDA Seed //
    //////////////

    const BREEDER_SEED: vector<u8> = b"BREEDER";

    //////////////////////////
    // COLLECTIONS SETTINGS //
    //////////////////////////

    const DRAGON_COLLECTION_MAX_SUPPLY: u64 = 10000;
    const SWORD_COLLECTION_MAX_SUPPLY: u64 = 1000;
    const ROYALTY_NUMERATOR: u64 = 1;
    const ROYALTY_DENOMINATOR: u64 = 10;

    ////////////////////////////
    // BREEDING TIME SETTINGS //
    ////////////////////////////

    const MINIMAL_BREEDING_TIME: u64 = 60 * 60 * 24;
    const MAXIMAL_BREEDING_TIME: u64 = 60 * 60 * 24 * 365 / 12;

    ////////////////////////
    // MONSTER PROPERTIES //
    ////////////////////////

    const DRAGON_PROPERTY_KEYS: vector<vector<u8>> = vector[b"Health", b"Defence", b"Strength", b"Ability"];
    const DRAGON_PROPERTY_TYPES: vector<vector<u8>> = vector[b"u64", b"u64", b"u64", b"0x1::string::String"];
    const DRAGON_MINIMAL_START_PROPERTY_VALUES: vector<u64> = vector[10, 0, 1];
    const DRAGON_MAXIMAL_START_PROPERTY_VALUES: vector<u64> = vector[100, 10, 20];

    /////////////////////////////
    // COMBINE AMOUNT SETTINGS //
    /////////////////////////////

    const MINIMAL_AMOUNT_TO_COMBINE: u64 = 2;
    const MAXIMAL_AMOUNT_TO_COMBINE: u64 = 10;

    //////////////////////////
    // EQUIPMENT PROPERTIES //
    //////////////////////////

    const SWORD_PROPERTY_KEYS: vector<vector<u8>> = vector[b"Attack", b"Durability", b"Ability"];
    const SWORD_PROPERTY_TYPES: vector<vector<u8>> = vector[b"u64", b"u64", b"0x1::string::String"];
    const SWORD_MINIMAL_START_PROPERTY_VALUES_SUM: u64 = 10;
    const SWORD_MAXIMAL_START_PROPERTY_VALUES_SUM: u64 = 100;

    /*
        Resource kept under admin address. Stores data about available collections.
    */
    struct State has key {
        // Breeder instance
        breeder: Breeder,
        // Combiner instance
        combiner: Combiner,
        // PDA's SingerCapability
        cap: SignerCapability
    }

    /*
        Holds data about dragon colections and ongoing breedings.
    */
    struct Breeder has store {
        // Available dragon collections and their corresponding names
        collections: SimpleMap<String, DragonRace>,
        // List of ongoing breedings and timestamps of when they going to finish
        ongoing_breedings: SimpleMap<vector<u8>, u64>,
        // Events
        create_dragon_collection_events: EventHandle<CreateDragonCollectionEvent>,
        create_dragon_events: EventHandle<CreateDragonEvent>,
        breed_dragons_events: EventHandle<BreedDragonsEvent>,
        hatch_dragon_events: EventHandle<HatchDragonEvent>
    }

    /*
        Holds data about a single monster collection
    */
    struct DragonRace has store, copy, drop {
        // Amount of time required for two dragons to hatch a new one
        breeding_time: u64,
        // Starting properties of a dragon created via create_dragon function
        starting_properties: vector<vector<u8>>,
    }

    /*
        Holds data about equipment collections
    */
    struct Combiner has store {
        // Available sword collections with their corresponding names
        collections: SimpleMap<String, SwordType>,
        // Events
        create_sword_collection_events: EventHandle<CreateSwordCollectionEvent>,
        create_sword_events: EventHandle<CreateSwordEvent>,
        combine_swords_events: EventHandle<CombineSwordsEvent>
    }

    /*
        Holds data about a single sword collection
    */
    struct SwordType has store, copy, drop {
        // Amount of sword tokens required to combine them into one
        combine_amount: u64,
        // Starting properties of sword created via create_sword function
        starting_properties: vector<vector<u8>>
    }

    /*
        Creates a PDA and initializes State resource
        @param admin - signer of the admin account
    */
    public entry fun init(admin: &signer) {
        // DONE: Assert the signer is the admin

        assert!(signer::address_of(admin) == @admin, ERROR_SIGNER_NOT_ADMIN);
        // DONE: Create resource account
        //
        let (pda, cap) = account::create_resource_account(admin, BREEDER_SEED);
        // DONE: Create State instance and move it to the admin
        let breeder = Breeder {
            // Available dragon collections and their corresponding names
            collections: simple_map::create<String, DragonRace>(), // SimpleMap<String, DragonRace>,
            // List of ongoing breedings and timestamps of when they going to finish
            ongoing_breedings: simple_map::create<vector<u8>, u64>(), // SimpleMap<vector<u8>, u64>,
            // Events
            create_dragon_collection_events: new_event_handle<CreateDragonCollectionEvent>(&pda),
            create_dragon_events: new_event_handle<CreateDragonEvent>(&pda),
            breed_dragons_events: new_event_handle<BreedDragonsEvent>(&pda),
            hatch_dragon_events: new_event_handle<HatchDragonEvent>(&pda),
        };
        let combiner = Combiner {
            // Available sword collections with their corresponding names
            collections: simple_map::create<String, SwordType>(),
            // Events
            create_sword_collection_events: new_event_handle<CreateSwordCollectionEvent>(&pda),
            create_sword_events: new_event_handle<CreateSwordEvent>(&pda),
            combine_swords_events: new_event_handle<CombineSwordsEvent>(&pda),
        };
        let state = State {
            // Breeder instance
            breeder,
            // Combiner instance
            combiner,
            // PDA's SignerCapability
            cap
        };
        move_to(admin, state)
    }

    /*
        Creates a new dragpm collection and adds it to Breeder's collections.
        @param account - an account signing the transaction
        @param name - name of the new collection
        @param description - description of the new collection
        @param uri - image's URI of the new collection
        @param breeding_time - amount of time NFTs will be frozen for while breeding
        @param ability_property - special ability of every NFT in the collection
    */
    public entry fun create_dragon_collection(
        _account: &signer,
        name: String,
        description: String,
        uri: String,
        breeding_time: u64,
        ability_property: String
    ) acquires State {
        // DONE: Assert that the state is initialized
        assert_state_initialized();
        let state = borrow_global_mut<State>(@admin);
        let pda = account::create_signer_with_capability(&state.cap);

        // DONE: Assert that breeding time is correct
        assert_breeding_time_is_correct(breeding_time);

        // DONE: Assert that a collection with provided name does not exist
        let (collections, _names) = simple_map::to_vec_pair<String, DragonRace>(
            state.breeder.collections
        );
        assert_collection_does_not_exist(&collections, &name);

        // DONE: Create a collection
        let  burnable = false; let freezable = true;
        // create_collection_internal(&pda, name, description, uri, DRAGON_COLLECTION_MAX_SUPPLY,
        //     burnable, freezable);
        create_collection_internal(&pda, name, description, uri, DRAGON_COLLECTION_MAX_SUPPLY,
            burnable, freezable);

        // DONE: Calculate monster starting properties
        let prefix_properties = calculate_dragons_starting_properties(breeding_time);
        let starting_properties = vector::empty<vector<u8>>();
        vector::for_each_ref(&prefix_properties, |property| {
            vector::push_back(&mut starting_properties, bcs::to_bytes(property));
        });

        // DONE: Push ability property to the starting properties
        vector::push_back(&mut starting_properties, bcs::to_bytes(&ability_property));

        // DONE: Add a new MonsterRace to Breeder's collections
        simple_map::add(&mut state.breeder.collections, name, DragonRace {
            breeding_time,
            starting_properties
        });

        // DONE: Emit CreateMonsterCollectionEvent event
        let create_dragon_collection_event =
            new_create_dragon_collection_event(
                name, description,
                uri, breeding_time, starting_properties, timestamp::now_seconds()
            );
        event::emit_event(&mut state.breeder.create_dragon_collection_events, create_dragon_collection_event);
    }

    /*
        Creates a new sword collection and adds it to Combiner's collections.
        @param account - signer of the transaction
        @param name - name of the new collection
        @param description - description of the new collection
        @param uri - image's URI of the new collection
        @param combine_amount - amount of NFT from this collection required to combined them into one
        @param ability_property - special ability of NFTs from this collection
    */
    public entry fun create_sword_collection(
        account: &signer,
        name: String,
        description: String,
        uri: String,
        combine_amount: u64,
        property_values: vector<u64>,
        ability_property: String
    ) acquires State {
        // DONE: Assert that combine amount is correct
        assert_combine_amount_is_correct(combine_amount);

        // DONE: Calculate equipment starting properties sum
        let starting_properties_sum = calculate_swords_starting_properties_sum(combine_amount);

        // DONE: Assert that sum of provided property_values is correct
        assert_sword_property_values_sum_is_correct(&property_values, starting_properties_sum);

        // DONE: Assert that state is initialized
        assert_state_initialized();
        let state = borrow_global_mut<State>(@admin);
        let pda = account::create_signer_with_capability(&state.cap);

        // DONE: Assert that collection with provided name does not exist
        let (sword_names, _sword_types) = simple_map::to_vec_pair(state.combiner.collections);
        assert_collection_does_not_exist(&sword_names, &name);

        // DONE: Create a collection
        // The collection cannot be created with the given account parameter
        // because the swords will the fail to be created under pda due to constraints imposed
        // so it is created under pda, therefore the account parameter is unused.
        let _account = account;

        // Easy readability
        let burnable = true;
        let freezable = false;
        create_collection_internal(&pda, name, description, uri, SWORD_COLLECTION_MAX_SUPPLY, burnable, freezable);

        // DONE: Create a new Equipment and add it to Combiner's collections
        let starting_properties = vector::map_ref(&property_values, |value| {
            bcs::to_bytes(value)
        });
        vector::push_back(&mut starting_properties, bcs::to_bytes(&ability_property));
        let equipment = SwordType {
            combine_amount,
            starting_properties,
        };
        simple_map::add(&mut state.combiner.collections, name, equipment);

        // DONE: Emit CreateEquipmentCollectionEvent event
        let create_sword_collection_event =
            breeder_events::new_create_sword_collection_event(
                name, description,
                uri, combine_amount, starting_properties, timestamp::now_seconds()
            );
        emit_event(&mut state.combiner.create_sword_collection_events, create_sword_collection_event);
    }

    /*
        Creates a new dragon NFT from provided collection.
        @param account - account, which the newly created token is transfered to
        @param collection_name - name of the collection
        @param dragon_name - name of the created dragon token
        @param dragon_description - description of the created dragon token
        @param dragon_uri - image's UTI of the created dragon token
    */
    public entry fun create_dragon(
        account: &signer,
        collection_name: String,
        dragon_name: String,
        dragon_description: String,
        dragon_uri: String
    ) acquires State {
        // DONE: Assert that state is initialized
        assert_state_initialized();
        let state = borrow_global_mut<State>(@admin);
        let pda = account::create_signer_with_capability(&state.cap);

        // DONE: Assert that collection with provided name exists
        let (dragon_collections, _dragons) = simple_map::to_vec_pair(state.breeder.collections);
        assert_collection_exists(&dragon_collections, &collection_name);

        // DONE: Create a variable holding PDA's GUID next creation number
        let pda_addr = signer::address_of(&pda);
        let creation_number = account::get_guid_next_creation_num(pda_addr);

        // DONE: Mint a new NFT / mints dragon
        let (dragon_token, _creation_number ) = mint_token(&pda, collection_name,
            dragon_name, dragon_description, dragon_uri, creation_number
        );

        // DONE: Transfer the NFT to the signer of the transaction
        aptos_token::unfreeze_transfer(&pda, dragon_token);
        let owner_addr = signer::address_of(account);
        object::transfer(&pda, dragon_token, owner_addr);

        // DONE: Emit CreateMonsterEvent event
        let account_addr = signer::address_of(account);
        let create_dragon_event = new_create_dragon_event(account_addr, collection_name, dragon_name,
            dragon_description, dragon_uri, creation_number, timestamp::now_seconds());
        event::emit_event(&mut state.breeder.create_dragon_events, create_dragon_event);
    }

    /*
        Creates a new sword token from provided collection
        @param account - account, which the newly created token is transfered to
        @param collection_name - name of the collection
        @param sword_name - name of the created sword token
        @param sword_description - description of the created sword token
        @param sword_uri - image's UTI of the created sword token
        @param amount - amount of tokens to be created
    */
    public entry fun create_sword(
        account: &signer,
        collection_name: String,
        sword_name: String,
        sword_description: String,
        sword_uri: String,
        amount: u64
    ) acquires State {
        // DONE: Assert that state is initialized
        assert_state_initialized();
        let state = borrow_global_mut<State>(@admin);
        // DONE: Assert that collection with provided name exists
        let (sword_collections, _swords) =
            simple_map::to_vec_pair(state.combiner.collections);
        assert_collection_exists(&sword_collections, &collection_name);

        // DONE: For every token to be created:
        //       1. Create a variable holding PDA's GUID next creation number
        //       2. Mint a new NFT
        //       3. Transfer the NFT to the signer of the transaction

        // Create a variable holding PDA's GUID next creation number, these numbers
        // are only updated when an object is created. If an object is not created
        // between calls to it, the return value doesn't change from the previous one
        let pda = account::create_signer_with_capability(&state.cap);
        let pda_addr = signer::address_of(&pda);

        let i = 0;
        let creation_numbers = vector[];
        let account_addr = signer::address_of(account);
        while (i < amount) {
            // Mint a new NFT
            let loop_creation_number = account::get_guid_next_creation_num(pda_addr);
            // mints_sword / mint sword.
            // loop_creation_number should match token_creation_num
            let (token, token_creation_num) = mint_token(&pda, collection_name,
                sword_name, sword_description, sword_uri, loop_creation_number
            );

            // Transfer the NFT to the signer of the transaction
            object::transfer(&pda, token, account_addr);

            vector::push_back(&mut creation_numbers, token_creation_num);
            i = i + 1;
        };

        // DONE: Emit CreateEquipmentEvent event
        let create_sword_event = new_create_sword_event(pda_addr, collection_name, sword_name,
            sword_description, sword_uri, amount, creation_numbers, timestamp::now_seconds());
        emit_event(&mut state.combiner.create_sword_events, create_sword_event);
    }

    /*
        Freezes both provided dragon tokens and adds a record to Breeder's ongoing_breedings
        @param owner - owner of the provided monster tokens
        @param collection_name - name of the collection, which the tokens are from
        @param first_dragon_creation_number - creation number of the first dragon token
        @param second_dragon_creation_number - creation number of the second dragon token
    */
    public entry fun breed_dragons(
        owner: &signer,
        collection_name: String,
        first_dragon_creation_number: u64,
        second_dragon_creation_number: u64
    ) acquires State {
        // DONE: Assert that state is initialized
        assert_state_initialized();

        // DONE: Assert that collection with provided name exists
        let state = borrow_global_mut<State>(@admin);
        let (dragons_collections, _dragon_race) = simple_map::to_vec_pair(state.breeder.collections);
        assert_collection_exists(&dragons_collections, &collection_name);

        // DONE: Assert that the signer owns the first monster token
        let pda = account::create_signer_with_capability(&state.cap);
        let owner_addr = signer::address_of(&pda);
        let first_dragon_address =
            object::create_guid_object_address(owner_addr, first_dragon_creation_number);
        let first_monster_token = object::address_to_object<Token>(first_dragon_address);
        assert_signer_owns_token(owner, first_monster_token);

        // DONE: Assert that the first monster token is from the provided collection
        assert_token_is_from_correct_collection(collection_name, first_monster_token);

        // DONE: Assert that the first monster is not breeding
        assert_dragon_not_breeding(first_monster_token);

        // DONE: Assert that the signer owns the second monster token
        let second_dragon_address =
            object::create_guid_object_address(owner_addr, second_dragon_creation_number);
        let second_monster_token = object::address_to_object<Token>(second_dragon_address);
        assert_signer_owns_token(owner, second_monster_token);

        // DONE: Assert that the second monster token is from the provided collection
        assert_token_is_from_correct_collection(collection_name, second_monster_token);

        // DONE: Assert that the second monster is not breeding
        assert_dragon_not_breeding(second_monster_token);

        // DONE: Create a hash from both of monster addresses
        let breeding_key_bytes = bcs::to_bytes(&first_dragon_address);
        vector::append(&mut breeding_key_bytes, bcs::to_bytes(&second_dragon_address));
        let breeding_key = aptos_hash::sha3_512(breeding_key_bytes);

        // DONE: Add new record to Breeder's ongoing_breedings
        let breeding_time = simple_map::borrow(&state.breeder.collections, &collection_name).breeding_time;
        let breeding_end = timestamp::now_seconds() + breeding_time;
        simple_map::add<vector<u8>, u64>(&mut state.breeder.ongoing_breedings, breeding_key, breeding_end);

        // DONE: Freeze transfer of both tokens
        aptos_token::freeze_transfer(&pda, first_monster_token);
        aptos_token::freeze_transfer(&pda, second_monster_token);

        // DONE: Emit BreedMonsterEvent event
        let owner_address = signer::address_of(owner);
        let new_breed_dragons_event = new_breed_dragons_event(owner_address, collection_name,
            first_dragon_creation_number, second_dragon_creation_number, breeding_end, timestamp::now_seconds()
        );
        event::emit_event(&mut state.breeder.breed_dragons_events, new_breed_dragons_event);
    }

    /*
        Unfreezes provided dragon tokens, creates new one with combined properties and transfers it to the owner.
        @param owner - owner of the two breeding dragon tokens
        @param first_dragon_creation_number - creation number of the first dragon token
        @param second_dragon_creation_number - creation number of the second dragon token
        @param new_dragon_name - name of the new dragon token
        @param new_dragon_description - description of the new dragon token
        @param new_dragon_uri - image's URI of the new dragon token
    */
    public entry fun hatch_dragon(
        owner: &signer,
        first_dragon_creation_number: u64,
        second_dragon_creation_number: u64,
        new_dragon_name: String,
        new_dragon_description: String,
        new_dragon_uri: String
    ) acquires State {
        // DONE: Assert that state is initialized
        assert_state_initialized();
        let state = borrow_global_mut<State>(@admin);
        let pda = account::create_signer_with_capability(&state.cap);
        let pda_addr = signer::address_of(&pda);
        // let owner_addr = signer::address_of(owner);

        // DONE: Assert that the signer owns the first monster token
        let first_dragon_address =
            object::create_guid_object_address(pda_addr, first_dragon_creation_number);
        let first_monster_token = object::address_to_object<Token>(first_dragon_address);
        assert_signer_owns_token(owner, first_monster_token);

        // DONE: Assert that the signer owns the second monster token
        let second_dragon_address =
            object::create_guid_object_address(pda_addr, second_dragon_creation_number);
        let second_monster_token = object::address_to_object<Token>(second_dragon_address);
        assert_signer_owns_token(owner, second_monster_token);

        // vectorize and simply the above ownership assertion
        let dragons_creation_numbers = vector[first_dragon_creation_number, second_dragon_creation_number];
        let dragons_race_property_values: vector<vector<vector<u8>>> = vector[];
        // vector<vector<vector<u8>>>>
        //         ^     ^
        //         |     | --> starting_properties [40 (example value), 3 (example value), 7 (example value), "encoded string in u8"] etc...
        //         |--> dragon race 1, 2, etc...
        vector::for_each(dragons_creation_numbers, |dragon_creation_number| {
            let dragon_address =
                object::create_guid_object_address(pda_addr, dragon_creation_number);
            let monster_token = object::address_to_object<Token>(dragon_address);
            assert_signer_owns_token(owner, monster_token);

            let dragon_collection_name = token::collection_name(monster_token);
            let dragon_race = simple_map::borrow<String, DragonRace>(&state.breeder.collections, &dragon_collection_name);
            vector::push_back(&mut dragons_race_property_values, dragon_race.starting_properties);
        });

        // DONE: Assert that the monsters are breeding
        // calculate the hash
        let breeding_key_bytes = bcs::to_bytes(&first_dragon_address);
        vector::append(&mut breeding_key_bytes, bcs::to_bytes(&second_dragon_address));
        let breeding_key = aptos_hash::sha3_512(breeding_key_bytes);

        // check breeding and finished using the hash
        assert_dragons_are_breeding(&state.breeder.ongoing_breedings, &breeding_key);

        // DONE: Assert that the breeding has finished
        assert_breeding_finished(&state.breeder.ongoing_breedings, &breeding_key);

        // DONE: Remove breeding record from Breeder's ongoing_breedings
        simple_map::remove(&mut state.breeder.ongoing_breedings, &breeding_key);

        // DONE: Unfreeze transfer of both monster tokens
        aptos_token::unfreeze_transfer(&pda, first_monster_token);
        aptos_token::unfreeze_transfer(&pda, second_monster_token);

        // DONE: Create a variable and save PDA's GUID next creation number
        let new_dragon_creation_number = account::get_guid_next_creation_num(pda_addr);

        // DONE: Combine properties of the monster tokens
        // let dragon_collection_name1 = token::collection_name(first_monster_token);
        // let _dragon_race1 = simple_map::borrow<String, DragonRace>(&state.breeder.collections, &dragon_collection_name1);
        // // second collection name is same as first one, so use the first token
        // let dragon_collection_name2 = token::collection_name(first_monster_token);
        // let _dragon_race2 = simple_map::borrow<String, DragonRace>(&state.breeder.collections, &dragon_collection_name2);

        let property_keys = vector<String>[];
        /***
            It's also possible to do this (construct the property keys inline),
            but using for_each below makes the code future-proof.

            let property_keys = vector<String>[
                string::utf8(b"Health"), string::utf8(b"Defence"),
                string::utf8(b"Strength"), string::utf8(b"Ability")
            ];
        ***/
        vector::for_each(DRAGON_PROPERTY_KEYS, |key| {
           vector::push_back(&mut property_keys, string::utf8(key));
        });
        let property_types = vector<String>[];
        vector::for_each(DRAGON_PROPERTY_TYPES, |type| {
           vector::push_back(&mut property_types, string::utf8(type));
        });

        // DONE: construct PropertyMap into Object(PropertyMap), alternate, create using vector<vector<vector<u8>>> instead
        // The above is wrong, because it changes the GUID next creation number
        // thus causing failure afterwards in the unit test
        let combined_properties_values = combine_properties_alternate(property_types, dragons_race_property_values);

        // DONE: Mint a new monster token @ pda, test using new function
        let dragon_collection_name = token::collection_name(first_monster_token);
        let (hatched_token, _) = mint_token_properties(&pda,
                dragon_collection_name, new_dragon_name, new_dragon_description, new_dragon_uri,
                new_dragon_creation_number, option::none(),
            property_keys, property_types, combined_properties_values
        );

        // DONE: Transfer the new monster token to the owner
        let new_dragon_owner_address = signer::address_of(owner);
        object::transfer(&pda, hatched_token, new_dragon_owner_address);

        // DONE: Emit HatchMonsterEvent event
        let hatch_monster_event = new_hatch_dragon_event(new_dragon_owner_address,
            first_dragon_creation_number, second_dragon_creation_number, new_dragon_creation_number,
            new_dragon_name, new_dragon_description, new_dragon_uri,
            combined_properties_values, timestamp::now_seconds()
        );
        event::emit_event(&mut state.breeder.hatch_dragon_events, hatch_monster_event);
    }

    /*
        Burns provided sword tokens, creates new one with combined properties and transfers it to the owner
        @param owner - owner of the provided sword tokens
        @param collection_name - name of the collection, which the tokens are from
        @param swords_creation_numbers - list of sword tokens to be burned
        @param new_sword_name - name of the new sword token
        @param new_sword_description - description of the new sword token
        @param new_sword_uri - image's URI of the new sword token
    */
    public entry fun combine_swords(
        owner: &signer,
        collection_name: String,
        swords_creation_numbers: vector<u64>,
        new_sword_name: String,
        new_sword_description: String,
        new_sword_uri: String
    ) acquires State {
        // DONE: Assert that state is initialized
        assert_state_initialized();
        let state = borrow_global_mut<State>(@admin);
        let pda = account::create_signer_with_capability(&state.cap);
        let pda_addr = signer::address_of(&pda);

        // DONE: Assert that amount of equipment to burn is correct
        let sword_type = simple_map::borrow(&state.combiner.collections, &collection_name);
        // The number of swords combined, is the same number of swords to be burnt.
        assert_amount_of_swords_is_correct(&swords_creation_numbers, sword_type.combine_amount);

        let sword_property_types = vector<String>[];
        let sword_property_keys = vector<String>[];
        vector::for_each(SWORD_PROPERTY_TYPES, |types| {
            vector::push_back(&mut sword_property_types, string::utf8(types));
        });
        vector::for_each(SWORD_PROPERTY_KEYS, |keys| {
            vector::push_back(&mut sword_property_keys, string::utf8(keys));
        });

        // DONE: For each of equipment's creation numbers
        //      1. Assert that the signer owns the token
        //      2. Assert that the token is from the provided collection
        //      3. Burn the token
        //      4. Push as many sword type's starting properties into the properties vector
        let i = 0;
        // combine_amount is same as length of swords_creation_numbers, asserted above
        let len = sword_type.combine_amount;
        let swords_property_values = vector[];
        while (i < len) {
            let creation_number = *vector::borrow(&swords_creation_numbers, i);
            let sword_address =
                object::create_guid_object_address(pda_addr, creation_number);
            let sword_token = object::address_to_object<Token>(sword_address);
            assert_signer_owns_token(owner, sword_token);
            assert_token_is_from_correct_collection(collection_name, sword_token);
            aptos_token::burn(&pda, sword_token);
            vector::push_back(&mut swords_property_values, sword_type.starting_properties);
            i = i + 1;
        };
        // DONE: Combine properties of the equipment
        let new_sword_properties = combine_properties_alternate(sword_property_types, swords_property_values);

        // DONE: Save PDA's GUID next creation number
        let pda = account::create_signer_with_capability(&state.cap);
        let pda_addr = signer::address_of(&pda);
        let new_sword_creation_number = account::get_guid_next_creation_num(pda_addr);

        // Mint the new equipment / sword NFT
        let (combined_sword_token, _)  = mint_token_properties(&pda, collection_name, new_sword_name,
            new_sword_description, new_sword_uri, new_sword_creation_number,
            option::none(),
            sword_property_keys, sword_property_types, new_sword_properties // this might fail, haven't check
        );

        // DONE: Transfer the new equipment NFT to the owner
        let new_sword_owner_addr = signer::address_of(owner);
        object::transfer(&pda, combined_sword_token, new_sword_owner_addr);
        let new_sword_property_values = vector[b""];
        let combine_swords_events = new_combine_swords_event(new_sword_owner_addr, collection_name,
            swords_creation_numbers, new_sword_creation_number, new_sword_name, new_sword_description, new_sword_uri,
            new_sword_property_values,
            timestamp::now_seconds()
        );
        event::emit_event(&mut state.combiner.combine_swords_events, combine_swords_events);
    }

    /*
        Returns sum of starting properties for provieded combine amount
        @param combine_amount - amount of sword tokens that would be combined
        @returns - sum of the starting properties
    */
    #[view]
    public fun get_equipment_starting_properties_sum(combine_amount: u64): u64 {
        // DONE: Assert that provided combine amount is correct
        assert_combine_amount_is_correct(combine_amount);

        // DONE: Calculate and return equipment starting properties sum
        calculate_swords_starting_properties_sum(combine_amount)
    }

    /*
        Wrapper for creating a new collection
        @param creator - creator of the collection
        @param name - name of the collection
        @param description - description of the new collection
        @param uri - image's URI of the new collection
        @param supply - supply of the new collection
        @param burnable - states if tokens from the collection are burnable
        @param freezable - states if tokens from the collection are freezable
    */
    inline fun create_collection_internal(
        creator: &signer,
        name: String,
        description: String,
        uri: String,
        supply: u64,
        burnable: bool,
        freezable: bool
    ) {
        // DONE: Call aptos_token::creation_collection function with appropriate parameters
        let royalty_numerator = 1u64; let royalty_denominator = 10u64;

        // Running test_create_dragon is failing, with this type
        aptos_token::create_collection(creator, description, supply, name, uri,
            false, false, false,
            false, false, false,
            false, burnable, freezable,
            royalty_numerator, royalty_denominator
        );

    }

    /*
        Converts byte representation of provided property parameters (keys, types, values) into string representation
        @param property_params - parameters of properties
        @returns - string representation of properties' parameters
    */
    inline fun get_property_params_as_strings(property_params: &vector<vector<u8>>): vector<String> {
        // DONE: Convert vector of byte representations into vector of string representations
        let result = vector::empty<String>();
        vector::for_each_ref(property_params, |param| {
           vector::push_back(&mut result, string::utf8(*param));
        });
        result
    }

    /*
        Calculates starting properties of dragons basing on provided breeding time
        @param breeding_time - time required for monsters to hatch a new one
        @returns - list of starting properties
    */
    inline fun calculate_dragons_starting_properties(breeding_time: u64): vector<u64> {
        // DONE: Calculate monster starting properties accordingly to the formula:
        //        (b_t - MIN_B_T)^3
        //      --------------------- * P_Diff + P_Min
        //      (MAX_B_T - MIN_B_T)^3
        // Where:
        //      b_t - breeding_time
        //      MIN_B_T - MINIMAL_BREEDING_TIME
        //      MAX_B_T - MAXIMAL_BREEDING_TIME
        //      P_Diff - Difference between minimal and maximal of one of monster start property values
        //      P_Min - Minimal value of one of monster start property values

        let result = vector[];
        let i = 0; let len = vector::length(&DRAGON_MAXIMAL_START_PROPERTY_VALUES);

        while (i < len) {
            let nominator = math64::pow(breeding_time - MINIMAL_BREEDING_TIME, 3);
            let denominator = math64::pow(MAXIMAL_BREEDING_TIME - MINIMAL_BREEDING_TIME, 3);

            let max = *vector::borrow(&DRAGON_MAXIMAL_START_PROPERTY_VALUES, i);
            let min = *vector::borrow(&DRAGON_MINIMAL_START_PROPERTY_VALUES, i);
            let p_diff = max - min;
            let p_min = min;

            let value = ((nominator as u256) * (p_diff as u256) / (denominator as u256)) + (p_min as u256);
            vector::push_back(&mut result, (value as u64));
            i = i + 1;
        };
        result
    }

    /*
        Calculates sum of starting properties of swords basing on provided combine amount
        @param combine_amount - amount of equipment tokens required to combine them into one
        @returns - sum of starting properties
    */
    inline fun calculate_swords_starting_properties_sum(combine_amount: u64): u64 {
        // DONE: Calculate sum of equipment starting properties accordingly to the formula:
        //          (c_a - MIN_AMOUNT)^2
        //      --------------------------- * P_Diff + P_MIN
        //      (MAX_AMOUNT - MIN_AMOUNT)^2
        // Where:
        //      c_a - combine_amount
        //      MIN_AMOUNT - MINIMAL_AMOUNT_OF_PIECES_TO_COMBINE
        //      MAX_AMOUNT - MAXIMAL_AMOUNT_OF_PIECES_TO_COMBINE
        //      P_Diff - Difference between EQUIPMENT_MAXIMAL_START_PROPERTY_VALUES_SUM and
        //          EQUIPMENT_MINIMAL_START_PROPERTY_VALUES_SUM
        //      P_MIN - EQUIPMENT_MINIMAL_START_PROPERTY_VALUES_SUM

        let nominator = math64::pow(combine_amount - MINIMAL_AMOUNT_TO_COMBINE, 2);
        let denominator = math64::pow(MAXIMAL_AMOUNT_TO_COMBINE - MINIMAL_AMOUNT_TO_COMBINE, 2);
        let p_diff = SWORD_MAXIMAL_START_PROPERTY_VALUES_SUM - SWORD_MINIMAL_START_PROPERTY_VALUES_SUM;
        let p_min = SWORD_MINIMAL_START_PROPERTY_VALUES_SUM;
        (nominator * p_diff / denominator) + p_min
    }

    /*
        Calculates combined properties for provided PropertyMap instances
        @param property_keys - property keys of a collection
        @param property_maps - PropertyMap instances of tokens
        @returns - combined property values
    */
    inline fun combine_properties_alternate(
        property_types: vector<String>,
        property_values: vector<vector<vector<u8>>>
    ): vector<vector<u8>> {
        // DONE: Assert that both vectors have the same length
        assert_property_vectors_lengths_alternate(&property_types, &property_values);

        // DONE: Create a vector for combined properties
        let result = vector::empty<vector<u8>>();
        let property_len = vector::length(&property_types);
        let property_index = 0;
        while (property_index < property_len) {
            let property_type = vector::borrow(&property_types, property_index);
            if (*string::bytes(property_type) == b"u64") {
                let default_value = 0u64;
                vector::push_back(&mut result, bcs::to_bytes(&default_value));
            } else {
                // empty
                vector::push_back(&mut result, vector[]);
            };
            property_index = property_index + 1;
        };

        // DONE: For each of property keys:
        //      1. Read property's type and value from each of property maps
        //          a. If the type is u64, then add it to an accumulator
        //          b. If the type is not u64, then push it to the vector and break looping through property maps
        //      2. If the accumulator does not have any value, then continue to the next iteration
        //      3. Otherwise, push the accumulator's value to the vector

        // const DRAGON_PROPERTY_TYPES: vector<vector<u8>> = vector[b"u64", b"u64", b"u64", b"0x1::string::String"];
        // const DRAGON_PROPERTY_KEYS: vector<vector<u8>> = vector[b"Health", b"Defence", b"Strength", b"Ability"];
        let dragon_race_index = 0; // can't do for_each as Move doesn't allow nested for_each
        let dragon_races_len = vector::length(&property_values);

        while (dragon_race_index < dragon_races_len) {
            let dragon_race_all_properties = vector::borrow(&mut property_values, dragon_race_index);

            let property_index = 0;
            while (property_index < property_len) {
                let property_type = vector::borrow(&property_types, property_index);

                let dragon_race_property_value_bytes = *vector::borrow(dragon_race_all_properties, property_index);
                let result_elem = vector::borrow_mut(&mut result, property_index);

                // property_type = "u64", "0x01::string::String", etc
                if (*string::bytes(property_type) == b"u64") {
                    let value = from_bcs::to_u64(*result_elem);
                    value = value + from_bcs::to_u64(dragon_race_property_value_bytes);
                    *result_elem = bcs::to_bytes<u64>(&value);
                } else {
                    if (vector::length(result_elem) == 0) {
                        *result_elem = dragon_race_property_value_bytes;
                    }
                };
                property_index = property_index + 1;
            };
            dragon_race_index = dragon_race_index + 1;
        };

        result
    }

    /*
        Calculates combined properties for provided PropertyMap instances
        @param property_keys - property keys of a collection
        @param property_maps - PropertyMap instances of tokens
        @returns - combined property values
    */
    inline fun combine_properties(
        property_keys: vector<String>,
        property_maps: vector<Object<PropertyMap>>
    ): vector<vector<u8>> {
        // DONE: Assert that both vectors have the same length
        assert_property_vectors_lengths(&property_keys, &property_maps);
        // DONE: Create a vector for combined properties
        let result = vector::empty<vector<u8>>();
        // DONE: For each of property keys:
        //      1. Read property's type and value from each of property maps
        //          a. If the type is u64, then add it to an accumulator
        //          b. If the type is not u64, then push it to the vector and break looping through property maps
        //      2. If the accumulator does not have any value, then continue to the next iteration
        //      3. Otherwise, push the accumulator's value to the vector
        let i = 0; let len = vector::length(&property_keys);
        while (i < len) {
            let prop_key = vector::borrow(&property_keys, i);
            let accum = 0u64;
            let j = 0; let prop_len = vector::length(&property_maps);
            while (j < prop_len) {
                let property = vector::borrow(&property_maps, j);
                let (type, value_vector) = property_map::read<PropertyMap>(property, prop_key);
                if (*string::bytes(&type) == b"u64") {
                    accum = accum + from_bcs::to_u64(value_vector);
                } else {
                    vector::push_back(&mut result, value_vector); // take the first
                    break
                };
                j = j + 1;
            };
            if (accum != 0) {
                vector::push_back(&mut result, bcs::to_bytes(&accum));
            };
            i = i + 1
        };
        result
    }

    fun mint_token_properties(
        account: &signer,
        collection_name: String,
        token_name: String,
        token_description: String,
        token_uri: String,
        token_creation_num: u64,
        maybe_royalty: Option<Royalty>,
        property_keys: vector<String>,
        property_types: vector<String>,
        property_values: vector<vector<u8>>
    ): (Object<Token>, u64) {
        let payee_addr = signer::address_of(account);
        let _royalty = option::some(royalty::create(25, 10000, payee_addr));
        // let mint_account_addr = signer::address_of(account);
        // let mint_token_creation_num = account::get_guid_next_creation_num(mint_account_addr);
        // in order to mint the token, the collection must already be at the collection creator's address
        aptos_token::mint(account, collection_name, token_description, token_name, token_uri,
            property_keys, property_types, property_values);

        let _royalty = maybe_royalty;

        let account_addr = signer::address_of(account);
        let token_addr = object::create_guid_object_address(account_addr, token_creation_num);
        let token = object::address_to_object<Token>(token_addr); // !!! To calculate address

        (token, token_creation_num)
    }

    inline fun mint_token(
        account: &signer,
        collection_name: String,
        token_name: String,
        token_description: String,
        token_uri: String,
        token_creation_num: u64
    ): (Object<Token>, u64) {
        mint_token_properties(account, collection_name, token_name,
            token_description, token_uri, token_creation_num,
            option::none(),
            vector[], vector[], vector[]
        )
    }

    /////////////
    // ASSERTS //
    /////////////

    inline fun assert_signer_is_admin(admin: &signer) {
        // DONE: Assert that address of the parameter is the same as admin in Move.toml
        assert!(signer::address_of(admin) == @admin, ERROR_SIGNER_NOT_ADMIN);
    }

    inline fun assert_state_initialized() {
        // DONE: Assert that State resource exists at the admin address
        assert!(exists<State>(@admin), ERROR_STATE_NOT_INITIALIZED);
    }

    inline fun assert_breeding_time_is_correct(breeding_time: u64) {
        // DONE: Assert that breeding_time is greater or equals to MINIMAL_BREEDING_TIME and is smaller or equals to
        //      MAXIMAL_BREEDING_TIME
        assert!(breeding_time >= MINIMAL_BREEDING_TIME && breeding_time <= MAXIMAL_BREEDING_TIME,
          ERROR_INVALID_BREEDING_TIME)
    }

    inline fun assert_combine_amount_is_correct(combine_amount: u64) {
        // DONE: Assert that combine_amount is greater or equals to MINIMAL_TO_COMBINE and is smaller
        //      or equals to MAXIMAL_AMOUNT_TO_COMBINE
        assert!(combine_amount >= MINIMAL_AMOUNT_TO_COMBINE && combine_amount <= MAXIMAL_AMOUNT_TO_COMBINE,
          ERROR_INVALID_COMBINE_AMOUNT)
    }

    inline fun assert_sword_property_values_sum_is_correct(property_values: &vector<u64>, expected_sum: u64) {
        // DONE: Assert that sum of property_values' values is smaller or equals expected_sum
        let expected_total = 0u64;
        vector::for_each(*property_values, |element| {
            expected_total = expected_total + element;
        });
        assert!(expected_total <= expected_sum, ERROR_INVALID_SWORDS_PROPERTY_VALUES_SUM)
    }

    inline fun assert_collection_does_not_exist(collections: &vector<String>, collection_name: &String) {
        // DONE: Assert that the vector does not contain the collection's name
        assert!(!vector::contains(collections, collection_name), ERROR_COLLECTION_ALREADY_EXISTS)
    }

    inline fun assert_collection_exists(collections: &vector<String>, collection_name: &String) {
        // DONE: Assert that the vector contains the collection's name
        assert!(vector::contains(collections, collection_name), ERROR_COLLECTION_DOES_NOT_EXIST)
    }

    inline fun assert_signer_owns_token(owner: &signer, token: Object<Token>) {
        // DONE: Assert that address of the owner is the same as the owner of the object
        assert!(object::is_owner(token, signer::address_of(owner)), ERROR_SIGNER_IS_NOT_THE_OWNER)
    }

    inline fun assert_dragon_not_breeding(monster: Object<Token>) {
        // DONE: Assert that transfer of the object is allowed
        assert!(ungated_transfer_allowed(monster), ERROR_DRAGON_DURING_BREEDING)
    }

    inline fun assert_dragons_are_breeding(
        ongoing_breedings: &SimpleMap<vector<u8>, u64>,
        dragons_pair_hash: &vector<u8>
    ) {
        // DONE: Assert that the map contains the provided key
        assert!(simple_map::contains_key(ongoing_breedings, dragons_pair_hash), ERROR_DRAGONS_NOT_BREEDING)
    }

    inline fun assert_breeding_finished(
        ongoing_breedings: &SimpleMap<vector<u8>, u64>,
        dragons_pair_hash: &vector<u8>
    ) {
        // DONE: Assert that timestamp related to the provided monster_pair_hash is smaller or equals current timestamp
        let now = timestamp::now_seconds();
        let dragons_pair_timestamp = *simple_map::borrow(ongoing_breedings, dragons_pair_hash);
        // debug::print(&string::utf8(b"dragons pair timestamp"));
        // debug::print(&dragons_pair_timestamp);
        // debug::print(&string::utf8(b"now in assert_breeding_finished"));
        // debug::print(&now);
        assert!(dragons_pair_timestamp <= now, ERROR_BREEDING_HAS_NOT_ENDED);
        // debug::print(&string::utf8(b"finished assert_breeding_finished"))
    }

    inline fun assert_amount_of_swords_is_correct(swords: &vector<u64>, combine_amount: u64) {
        // DONE: Assert that the vector's length equals to combine_amount
        assert!(vector::length(swords) == combine_amount, ERROR_INCORRECT_AMOUNT_OF_SWORDS)
    }

    // to implement in future
    // inline fun assert_property_vectors_lengths_diff_implementations_worked_similarly(): bool {
    //     false
    // }
    //
    // #[test]
    // fun test_diff_vector_length_impl_work() {
    //     // use error based on line number
    //     assert!(assert_property_vectors_lengths_diff_implementations_worked_similarly(), 1262);
    // }
    //
    // inline fun assert_diff_combine_properties_work_in_same_way(): bool {
    //     false
    // }
    //
    // #[test]
    // fun test_diff_combine_properties_impl_work() {
    //     // use error based on line number
    //     assert!(assert_diff_combine_properties_work_in_same_way(), 1276);
    // }

    inline fun assert_property_vectors_lengths_alternate(
        property_keys: &vector<String>,
        properties: &vector<vector<vector<u8>>>
    ) {
        // DONE: Assert that each of the inner vector length equals to number of keys in property_keys
        let key_len = vector::length(property_keys);
        vector::for_each<vector<vector<u8>>>(*properties, |dragon_races_property| {
            let dragon_races_property: vector<vector<u8>> = dragon_races_property;
            // debug::print(&string::utf8(b"dump dragon_races_property"));
            // debug::print(&dragon_races_property);
            // debug::print(&string::utf8(b"vector length dragon_race_property"));
            // debug::print(&vector::length(&dragon_races_property));
            assert!(vector::length(&dragon_races_property) == key_len, ERROR_PROPERTY_LENGTH_MISMATCH);
        });
    }

    inline fun assert_property_vectors_lengths(
        property_keys: &vector<String>,
        properties: &vector<Object<PropertyMap>>
    ) {
        // DONE: Assert that each of the property maps length equals to number of keys in property_keys
        let key_len = vector::length(property_keys);
        vector::for_each_ref<Object<PropertyMap>>(properties, |property| {
            assert!(property_map::length(property) == key_len, ERROR_PROPERTY_LENGTH_MISMATCH);
        });
    }

    inline fun assert_token_is_from_correct_collection(collection_name: String, token: Object<Token>) {
        // DONE: Assert that collection of the token is the same as collection_name
        assert!(token::collection_name(token) == collection_name, ERROR_TOKEN_FROM_WRONG_COLLECTION)
    }

    ///////////
    // TESTS //
    ///////////

    #[test]
    fun test_create_collection_internal() {
        let creator = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"My new collection");
        let description = string::utf8(b"This is my first collection");
        let uri = string::utf8(b"https://i1.sndcdn.com/artworks-000032011179-v3cdjs-t500x500.jpg");

        create_collection_internal(&creator, name, description, uri, 50, false, false);

        let collection_address = collection::create_collection_address(&@0xCAFE, &name);
        let collection_object = object::address_to_object<Collection>(collection_address);
        assert!(option::is_some(&collection::count(collection_object)), 0);
        assert!(*option::borrow(&collection::count(collection_object)) == 0, 1);
        assert!(collection::creator(collection_object) == @0xCAFE, 2);
        assert!(collection::description(collection_object) == description, 3);
        assert!(collection::name(collection_object) == name, 4);
        assert!(collection::uri(collection_object) == uri, 5);
        assert!(royalty::exists_at(collection_address), 6);

        let maybe_royalty = royalty::get(collection_object);
        assert!(option::is_some(&maybe_royalty), 7);

        let royalty = option::extract(&mut maybe_royalty);
        assert!(royalty::denominator(&royalty) == 10, 8);
        assert!(royalty::numerator(&royalty) == 1, 9);

        assert!(!aptos_token::is_mutable_collection_description(collection_object), 10);
        assert!(!aptos_token::is_mutable_collection_royalty(collection_object), 11);
        assert!(!aptos_token::is_mutable_collection_uri(collection_object), 12);
        assert!(!aptos_token::is_mutable_collection_description(collection_object), 13);
        assert!(!aptos_token::is_mutable_collection_token_name(collection_object), 14);
        assert!(!aptos_token::is_mutable_collection_token_properties(collection_object), 15);
        assert!(!aptos_token::are_collection_tokens_burnable(collection_object), 16);
        assert!(!aptos_token::are_collection_tokens_freezable(collection_object), 17);
    }

    #[test]
    fun test_get_property_params_as_strings() {
        let property_keys = vector[b"First key", b"Second key", b"Third key"];
        let property_keys_strings = get_property_params_as_strings(&property_keys);
        assert!(
            property_keys_strings ==
                vector[
                    string::utf8(b"First key"),
                    string::utf8(b"Second key"),
                    string::utf8(b"Third key")
                ],
            0
        );
    }

    #[test]
    fun test_calculate_dragons_starting_properties() {
        let breeding_time = MINIMAL_BREEDING_TIME;
        let starting_properties = calculate_dragons_starting_properties(breeding_time);
        assert!(starting_properties == DRAGON_MINIMAL_START_PROPERTY_VALUES, 0);

        let breeding_time = MAXIMAL_BREEDING_TIME;
        let starting_properties = calculate_dragons_starting_properties(breeding_time);
        assert!(starting_properties == DRAGON_MAXIMAL_START_PROPERTY_VALUES, 1);

        let breeding_time = 60 * 60 * 24 * 16;
        let starting_properties = calculate_dragons_starting_properties(breeding_time);
        assert!(*vector::borrow(&starting_properties, 0) == 21, 2);
        assert!(*vector::borrow(&starting_properties, 1) == 1, 3);
        assert!(*vector::borrow(&starting_properties, 2) == 3, 4);
    }

    #[test]
    fun test_calculate_swords_starting_properties_sum() {
        let combine_amount = 2;
        let starting_properties_sum = calculate_swords_starting_properties_sum(combine_amount);
        assert!(starting_properties_sum == SWORD_MINIMAL_START_PROPERTY_VALUES_SUM, 0);

        let combine_amount = 10;
        let starting_properties_sum = calculate_swords_starting_properties_sum(combine_amount);
        assert!(starting_properties_sum == SWORD_MAXIMAL_START_PROPERTY_VALUES_SUM, 1);

        let combine_amount = 6;
        let starting_properties_sum = calculate_swords_starting_properties_sum(combine_amount);
        assert!(starting_properties_sum == 32, 2);
    }

    #[test]
    fun test_combine_properties() {
        let property_keys = vector[
            string::utf8(b"First key"),
            string::utf8(b"Second key"),
            string::utf8(b"Third key"),
            string::utf8(b"Fourth key"),
            string::utf8(b"Fifth key")
        ];
        let property_types = vector[
            string::utf8(b"u64"),
            string::utf8(b"u64"),
            string::utf8(b"0x1::string::String"),
            string::utf8(b"address"),
            string::utf8(b"u64")
        ];
        let property_maps = vector[
            property_map::prepare_input(
                property_keys,
                property_types,
                vector[
                    bcs::to_bytes(&150),
                    bcs::to_bytes(&46),
                    bcs::to_bytes(&string::utf8(b"Random ability")),
                    bcs::to_bytes(&@0xACE),
                    bcs::to_bytes(&111)
                ]
            ),
            property_map::prepare_input(
                property_keys,
                property_types,
                vector[
                    bcs::to_bytes(&45),
                    bcs::to_bytes(&11),
                    bcs::to_bytes(&string::utf8(b"Random ability")),
                    bcs::to_bytes(&@0xACE),
                    bcs::to_bytes(&111)
                ]
            ),
            property_map::prepare_input(
                property_keys,
                property_types,
                vector[
                    bcs::to_bytes(&846),
                    bcs::to_bytes(&5),
                    bcs::to_bytes(&string::utf8(b"Random ability")),
                    bcs::to_bytes(&@0xACE),
                    bcs::to_bytes(&111)
                ]
            ),
        ];
        let creator = account::create_account_for_test(@0xCAFE);
        let property_map_objects = vector::map(property_maps, |property_map| {
            let creation_number = account::get_guid_next_creation_num(@0xCAFE);
            let constructor_ref = object::create_object_from_account(&creator);
            property_map::init(&constructor_ref, property_map);

            let property_map_address = object::create_guid_object_address(@0xCAFE, creation_number);
            object::address_to_object<PropertyMap>(property_map_address)
        });

        let combined_properties = combine_properties(property_keys, property_map_objects);
        assert!(vector::length(&combined_properties) == vector::length(&property_keys), 0);
        assert!(from_bcs::to_u64(*vector::borrow(&combined_properties, 0)) == 1041, 1);
        assert!(from_bcs::to_u64(*vector::borrow(&combined_properties, 1)) == 62, 2);
        assert!(
            from_bcs::to_string(*vector::borrow(&combined_properties, 2)) ==
                string::utf8(b"Random ability"),
            3
        );
        assert!(from_bcs::to_address(*vector::borrow(&combined_properties, 3)) == @0xACE, 4);
        assert!(from_bcs::to_u64(*vector::borrow(&combined_properties, 4)) == 333, 5);
    }

    #[test]
    fun test_init() acquires State {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 0, 0);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 1);
        assert!(simple_map::length(&state.combiner.collections) == 0, 2);
        assert!(event::counter(&state.breeder.create_dragon_collection_events) == 0, 3);
        assert!(event::counter(&state.breeder.create_dragon_events) == 0, 4);
        assert!(event::counter(&state.breeder.breed_dragons_events) == 0, 5);
        assert!(event::counter(&state.breeder.hatch_dragon_events) == 0, 6);
        assert!(event::counter(&state.combiner.create_sword_collection_events) == 0, 7);
        assert!(event::counter(&state.combiner.create_sword_events) == 0, 8);
        assert!(event::counter(&state.combiner.combine_swords_events) == 0, 9);

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);
        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 10);
    }

    #[test]
    #[expected_failure(abort_code = 0, location = Self)]
    fun test_init_signer_not_admin() {
        let account = account::create_account_for_test(@0xACE);
        init(&account);
    }

    #[test]
    #[expected_failure(abort_code = 524303, location = aptos_framework::account)]
    fun test_init_resource_account_already_exists() {
        let admin = account::create_account_for_test(@admin);
        init(&admin);
        init(&admin);
    }

    #[test]
    fun test_create_dragon_collection() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Dragon collection");
        let description = string::utf8(b"This is a dragon collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(&account, name, description, uri, breeding_time, ability_property);

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 1, 0);
        assert!(simple_map::contains_key(&state.breeder.collections, &name), 1);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 2);
        assert!(event::counter(&state.breeder.create_dragon_collection_events) == 1, 3);
        assert!(event::counter(&state.breeder.create_dragon_events) == 0, 4);
        assert!(event::counter(&state.breeder.breed_dragons_events) == 0, 5);
        assert!(event::counter(&state.breeder.hatch_dragon_events) == 0, 6);
        assert!(simple_map::length(&state.combiner.collections) == 0, 7);
        assert!(event::counter(&state.combiner.create_sword_collection_events) == 0, 8);
        assert!(event::counter(&state.combiner.create_sword_events) == 0, 9);
        assert!(event::counter(&state.combiner.combine_swords_events) == 0, 10);

        let dragon_race = simple_map::borrow(&state.breeder.collections, &name);
        assert!(dragon_race.breeding_time == breeding_time, 11);

        let expected_starting_properties = vector[
            bcs::to_bytes(&40),
            bcs::to_bytes(&3),
            bcs::to_bytes(&7),
            bcs::to_bytes(&ability_property)
        ];
        assert!(dragon_race.starting_properties == expected_starting_properties, 12);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_create_dragon_collection_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Dragon collection");
        let description = string::utf8(b"This is a dragon collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(&account, name, description, uri, breeding_time, ability_property);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_create_dragon_collection_incorrect_breeding_time_too_small() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Dragon collection");
        let description = string::utf8(b"This is a dragon collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(&account, name, description, uri, breeding_time, ability_property);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_create_dragon_collection_incorrect_breeding_time_too_big() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Dragon collection");
        let description = string::utf8(b"This is a dragon collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 5646851151;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(&account, name, description, uri, breeding_time, ability_property);
    }

    #[test]
    #[expected_failure(abort_code = 5, location = Self)]
    fun test_create_dragon_collection_already_exists() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Dragon collection");
        let description = string::utf8(b"This is a dragon collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 13;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(&account, name, description, uri, breeding_time, ability_property);
        create_dragon_collection(&account, name, description, uri, breeding_time, ability_property);
    }

    #[test]
    fun test_create_sword_collection() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Sword collection");
        let description = string::utf8(b"This is a sword collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 0, 0);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 1);
        assert!(event::counter(&state.breeder.create_dragon_collection_events) == 0, 2);
        assert!(event::counter(&state.breeder.create_dragon_events) == 0, 3);
        assert!(event::counter(&state.breeder.breed_dragons_events) == 0, 4);
        assert!(event::counter(&state.breeder.hatch_dragon_events) == 0, 5);
        assert!(simple_map::length(&state.combiner.collections) == 1, 6);
        assert!(simple_map::contains_key(&state.combiner.collections, &name), 7);
        assert!(event::counter(&state.combiner.create_sword_collection_events) == 1, 8);
        assert!(event::counter(&state.combiner.create_sword_events) == 0, 9);
        assert!(event::counter(&state.combiner.combine_swords_events) == 0, 10);

        let sword_type = simple_map::borrow(&state.combiner.collections, &name);
        assert!(sword_type.combine_amount == combine_amount, 11);

        let expected_starting_properties = vector::map_ref(&property_values, |value| {
            bcs::to_bytes(value)
        });
        vector::push_back(&mut expected_starting_properties, bcs::to_bytes(&ability_property));
        assert!(sword_type.starting_properties == expected_starting_properties, 12);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_create_sword_collection_incorrect_combine_amount_too_small() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Sword collection");
        let description = string::utf8(b"This is a sword collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 1;
        let property_values = vector[10, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
    }

    #[test]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_create_sword_collection_incorrect_combine_amount_too_big() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Sword collection");
        let description = string::utf8(b"This is a sword collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 2222;
        let property_values = vector[10, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
    }

    #[test]
    #[expected_failure(abort_code = 4, location = Self)]
    fun test_create_sword_collection_incorrect_property_values_sum() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Sword collection");
        let description = string::utf8(b"This is a sword collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 55, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_create_sword_collection_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Sword collection");
        let description = string::utf8(b"This is a sword collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 0, 3];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
    }

    #[test]
    #[expected_failure(abort_code = 5, location = Self)]
    fun test_create_sword_collection_already_exists() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Sword collection");
        let description = string::utf8(b"This is a sword collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 0, 3];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
        create_sword_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
    }

    #[test]
    fun test_create_dragon() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);
        let creation_number = account::get_guid_next_creation_num(resource_account_address);

        let dragon_name = string::utf8(b"The first dragon");
        let dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, dragon_name, dragon_description, dragon_uri);

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 1, 0);
        assert!(simple_map::contains_key(&state.breeder.collections, &collection_name), 1);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 2);
        assert!(event::counter(&state.breeder.create_dragon_collection_events) == 1, 3);
        assert!(event::counter(&state.breeder.create_dragon_events) == 1, 4);
        assert!(event::counter(&state.breeder.breed_dragons_events) == 0, 5);
        assert!(event::counter(&state.breeder.hatch_dragon_events) == 0, 6);
        assert!(simple_map::length(&state.combiner.collections) == 0, 7);
        assert!(event::counter(&state.combiner.create_sword_collection_events) == 0, 8);
        assert!(event::counter(&state.combiner.create_sword_events) == 0, 9);
        assert!(event::counter(&state.combiner.combine_swords_events) == 0, 10);

        let dragon_race = simple_map::borrow(&state.breeder.collections, &collection_name);
        assert!(dragon_race.breeding_time == breeding_time, 11);

        let expected_starting_properties = vector[
            bcs::to_bytes(&40),
            bcs::to_bytes(&3),
            bcs::to_bytes(&7),
            bcs::to_bytes(&ability_property)
        ];
        assert!(dragon_race.starting_properties == expected_starting_properties, 12);

        let token_address = object::create_guid_object_address(resource_account_address, creation_number);
        let token_object = object::address_to_object<Token>(token_address);
        assert!(!aptos_token::are_properties_mutable(token_object), 13);
        assert!(!aptos_token::is_burnable(token_object), 14);
        assert!(aptos_token::is_freezable_by_creator(token_object), 15);
        assert!(!aptos_token::is_mutable_description(token_object), 16);
        assert!(!aptos_token::is_mutable_name(token_object), 17);
        assert!(!aptos_token::is_mutable_uri(token_object), 18);
        assert!(token::creator(token_object) == resource_account_address, 19);
        assert!(token::collection_name(token_object) == collection_name, 20);
        assert!(token::description(token_object) == dragon_description, 21);
        assert!(token::name(token_object) == dragon_name, 22);
        assert!(token::uri(token_object) == dragon_uri, 23);

        let maybe_token_royalty = token::royalty(token_object);
        assert!(option::is_some(&maybe_token_royalty), 24);

        let token_royalty = option::extract(&mut maybe_token_royalty);
        assert!(royalty::denominator(&token_royalty) == 10, 25);
        assert!(royalty::numerator(&token_royalty) == 1, 26);
        assert!(royalty::payee_address(&token_royalty) == resource_account_address, 27);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_create_dragon_state_not_initalized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let dragon_name = string::utf8(b"The first dragon");
        let dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, dragon_name, dragon_description, dragon_uri);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_create_dragon_collection_does_not_exist() acquires State {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let dragon_name = string::utf8(b"The first dragon");
        let dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, dragon_name, dragon_description, dragon_uri);
    }

    #[test]
    fun test_create_sword() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Sword collection");
        let collection_description = string::utf8(b"This is a sword collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            combine_amount,
            property_values,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);
        let creation_number = account::get_guid_next_creation_num(resource_account_address);

        let sword_name = string::utf8(b"Eggscalibur");
        let sword_description = string::utf8(b"For a true chef");
        let sword_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_sword(&account, collection_name, sword_name, sword_description, sword_uri, 2);

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 0, 0);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 1);
        assert!(event::counter(&state.breeder.create_dragon_collection_events) == 0, 2);
        assert!(event::counter(&state.breeder.create_dragon_events) == 0, 3);
        assert!(event::counter(&state.breeder.breed_dragons_events) == 0, 4);
        assert!(event::counter(&state.breeder.hatch_dragon_events) == 0, 5);
        assert!(simple_map::length(&state.combiner.collections) == 1, 6);
        assert!(simple_map::contains_key(&state.combiner.collections, &collection_name), 7);
        assert!(event::counter(&state.combiner.create_sword_collection_events) == 1, 8);
        assert!(event::counter(&state.combiner.create_sword_events) == 1, 9);
        assert!(event::counter(&state.combiner.combine_swords_events) == 0, 10);

        let equipment = simple_map::borrow(&state.combiner.collections, &collection_name);
        assert!(equipment.combine_amount == combine_amount, 11);

        let expected_starting_properties = vector::map_ref(&property_values, |value| {
            bcs::to_bytes(value)
        });
        vector::push_back(&mut expected_starting_properties, bcs::to_bytes(&ability_property));
        assert!(equipment.starting_properties == expected_starting_properties, 12);

        let counter = 0;
        while (counter <= 1) {
            let token_address =
                object::create_guid_object_address(resource_account_address, creation_number + counter);
            let token_object = object::address_to_object<Token>(token_address);
            assert!(!aptos_token::are_properties_mutable(token_object), 13 + 15 * counter);
            assert!(aptos_token::is_burnable(token_object), 14 + 15 * counter);
            assert!(!aptos_token::is_freezable_by_creator(token_object), 15 + 15 * counter);
            assert!(!aptos_token::is_mutable_description(token_object), 16 + 15 * counter);
            assert!(!aptos_token::is_mutable_name(token_object), 17 + 15 * counter);
            assert!(!aptos_token::is_mutable_uri(token_object), 18 + 15 * counter);
            assert!(token::creator(token_object) == resource_account_address, 19 + 15 * counter);
            assert!(token::collection_name(token_object) == collection_name, 20 + 15 * counter);
            assert!(token::description(token_object) == sword_description, 21 + 15 * counter);
            assert!(token::name(token_object) == sword_name, 22 + 15 * counter);
            assert!(token::uri(token_object) == sword_uri, 23 + 15 * counter);

            let maybe_token_royalty = token::royalty(token_object);
            assert!(option::is_some(&maybe_token_royalty), 24 + 15 * counter);

            let token_royalty = option::extract(&mut maybe_token_royalty);
            assert!(royalty::denominator(&token_royalty) == 10, 25 + 15 * counter);
            assert!(royalty::numerator(&token_royalty) == 1, 26 + 15 * counter);
            assert!(royalty::payee_address(&token_royalty) == resource_account_address, 27 + 15 * counter);

            counter = counter + 1;
        };
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_create_sword_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Sword collection");
        let sword_name = string::utf8(b"Eggscalibur");
        let sword_description = string::utf8(b"For a true chef");
        let sword_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_sword(&account, collection_name, sword_name, sword_description, sword_uri, 2);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_create_sword_collection_does_not_exist() acquires State {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Sword collection");
        let sword_name = string::utf8(b"Eggscalibur");
        let sword_description = string::utf8(b"For a true chef");
        let sword_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_sword(&account, collection_name, sword_name, sword_description, sword_uri, 2);
    }

    #[test]
    fun test_breed_dragons() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        let current_timestamp = timestamp::now_seconds();
        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 1, 0);
        assert!(simple_map::contains_key(&state.breeder.collections, &collection_name), 1);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 1, 2);
        assert!(event::counter(&state.breeder.create_dragon_collection_events) == 1, 3);
        assert!(event::counter(&state.breeder.create_dragon_events) == 2, 4);
        assert!(event::counter(&state.breeder.breed_dragons_events) == 1, 5);
        assert!(event::counter(&state.breeder.hatch_dragon_events) == 0, 6);
        assert!(simple_map::length(&state.combiner.collections) == 0, 7);
        assert!(event::counter(&state.combiner.create_sword_collection_events) == 0, 8);
        assert!(event::counter(&state.combiner.create_sword_events) == 0, 9);
        assert!(event::counter(&state.combiner.combine_swords_events) == 0, 10);

        let first_dragon_address =
            object::create_guid_object_address(resource_account_address, first_creation_number);
        let second_dragon_address =
            object::create_guid_object_address(resource_account_address, second_creation_number);
        let breeding_key_bytes = bcs::to_bytes(&first_dragon_address);
        vector::append(&mut breeding_key_bytes, bcs::to_bytes(&second_dragon_address));

        let breeding_key = aptos_hash::sha3_512(breeding_key_bytes);
        assert!(simple_map::contains_key(&state.breeder.ongoing_breedings, &breeding_key), 11);

        let breeding_time =
            simple_map::borrow(&state.breeder.collections, &collection_name).breeding_time;
        let breeding_end = *simple_map::borrow(&state.breeder.ongoing_breedings, &breeding_key);
        let lower_limit = if (current_timestamp > 0) {
            current_timestamp + breeding_time - 1
        } else {
            current_timestamp + breeding_time
        };
        assert!(lower_limit <= breeding_end && breeding_end <= current_timestamp + breeding_time + 1, 12);

        let dragon_race = simple_map::borrow(&state.breeder.collections, &collection_name);
        assert!(dragon_race.breeding_time == breeding_time, 13);

        let expected_starting_properties = vector[
            bcs::to_bytes(&40),
            bcs::to_bytes(&3),
            bcs::to_bytes(&7),
            bcs::to_bytes(&ability_property)
        ];
        assert!(dragon_race.starting_properties == expected_starting_properties, 14);

        let first_dragon_token = object::address_to_object<Token>(first_dragon_address);
        assert!(!object::ungated_transfer_allowed(first_dragon_token), 15);

        let second_dragon_token = object::address_to_object<Token>(second_dragon_address);
        assert!(!object::ungated_transfer_allowed(second_dragon_token), 16);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_breed_dragons_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        breed_dragons(&account, collection_name, 156, 54);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_breed_dragons_collection_does_not_exist() acquires State {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        breed_dragons(&account, collection_name, 156, 54);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_breed_dragons_signer_does_not_own_the_first_token() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        let first_dragon_address =
            object::create_guid_object_address(resource_account_address, first_creation_number);
        object::transfer_raw(&account, first_dragon_address, @0xBEEF);

        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_breed_dragons_signer_does_not_own_the_second_token() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        let second_dragon_address =
            object::create_guid_object_address(resource_account_address, second_creation_number);
        object::transfer_raw(&account, second_dragon_address, @0xBEEF);

        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);
    }

    #[test]
    #[expected_failure(abort_code = 13, location = Self)]
    fun test_breed_dragon_first_monster_from_incorrect_collection() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let another_collection_name = string::utf8(b"Dragon collection 2");
        let another_collection_description = string::utf8(b"This is another dragon collection");
        let another_collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let another_breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let another_ability_property = string::utf8(b"BEET");
        create_dragon_collection(
            &account,
            another_collection_name,
            another_collection_description,
            another_collection_uri,
            another_breeding_time,
            another_ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, another_collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);
    }

    #[test]
    #[expected_failure(abort_code = 13, location = Self)]
    fun test_breed_dragon_second_monster_from_incorrect_collection() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let another_collection_name = string::utf8(b"Dragon collection 2");
        let another_collection_description = string::utf8(b"This is another dragon collection");
        let another_collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let another_breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let another_ability_property = string::utf8(b"BEET");
        create_dragon_collection(
            &account,
            another_collection_name,
            another_collection_description,
            another_collection_uri,
            another_breeding_time,
            another_ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, another_collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = Self)]
    fun test_breed_dragons_first_monster_already_breeding() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);

        let third_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let third_dragon_name = string::utf8(b"The third dragon");
        let third_dragon_description = string::utf8(b"This is another dragon in this collection");
        let third_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, third_dragon_name, third_dragon_description, third_dragon_uri);

        breed_dragons(&account, collection_name, first_creation_number, third_creation_number);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = Self)]
    fun test_breed_dragons_second_monster_already_breeding() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);

        let third_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let third_dragon_name = string::utf8(b"The third dragon");
        let third_dragon_description = string::utf8(b"This is another dragon in this collection");
        let third_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, third_dragon_name, third_dragon_description, third_dragon_uri);

        breed_dragons(&account, collection_name, third_creation_number, second_creation_number);
    }

    #[test]
    fun test_hatch_dragon() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);
        timestamp::fast_forward_seconds(breeding_time);

        let new_dragon_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let new_dragon_name = string::utf8(b"Baby dragon");
        let new_dragon_description = string::utf8(b"This is a newly born baby dragon!");
        let new_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        hatch_dragon(
            &account,
            first_creation_number,
            second_creation_number,
            new_dragon_name,
            new_dragon_description,
            new_dragon_uri
        );

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 1, 0);
        assert!(simple_map::contains_key(&state.breeder.collections, &collection_name), 1);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 2);
        assert!(event::counter(&state.breeder.create_dragon_collection_events) == 1, 3);
        assert!(event::counter(&state.breeder.create_dragon_events) == 2, 4);
        assert!(event::counter(&state.breeder.breed_dragons_events) == 1, 5);
        assert!(event::counter(&state.breeder.hatch_dragon_events) == 1, 6);
        assert!(simple_map::length(&state.combiner.collections) == 0, 7);
        assert!(event::counter(&state.combiner.create_sword_collection_events) == 0, 8);
        assert!(event::counter(&state.combiner.create_sword_events) == 0, 9);
        assert!(event::counter(&state.combiner.combine_swords_events) == 0, 10);

        let dragon_race = simple_map::borrow(&state.breeder.collections, &collection_name);
        assert!(dragon_race.breeding_time == breeding_time, 11);

        let expected_starting_properties = vector[
            bcs::to_bytes(&40),
            bcs::to_bytes(&3),
            bcs::to_bytes(&7),
            bcs::to_bytes(&ability_property)
        ];
        assert!(dragon_race.starting_properties == expected_starting_properties, 12);

        let first_dragon_address =
            object::create_guid_object_address(resource_account_address, first_creation_number);
        let first_dragon_token = object::address_to_object<Token>(first_dragon_address);
        assert!(object::ungated_transfer_allowed(first_dragon_token), 13);

        let second_dragon_address =
            object::create_guid_object_address(resource_account_address, second_creation_number);
        let second_dragon_token = object::address_to_object<Token>(second_dragon_address);
        assert!(object::ungated_transfer_allowed(second_dragon_token), 14);

        let new_dragon_address =
            object::create_guid_object_address(resource_account_address, new_dragon_creation_number);
        let new_dragon_token = object::address_to_object<Token>(new_dragon_address);
        assert!(!aptos_token::are_properties_mutable(new_dragon_token), 15);
        assert!(!aptos_token::is_burnable(new_dragon_token), 16);
        assert!(aptos_token::is_freezable_by_creator(new_dragon_token), 17);
        assert!(!aptos_token::is_mutable_description(new_dragon_token), 18);
        assert!(!aptos_token::is_mutable_name(new_dragon_token), 19);
        assert!(!aptos_token::is_mutable_uri(new_dragon_token), 20);
        assert!(token::creator(new_dragon_token) == resource_account_address, 21);
        assert!(token::collection_name(new_dragon_token) == collection_name, 22);
        assert!(token::description(new_dragon_token) == new_dragon_description, 23);
        assert!(token::name(new_dragon_token) == new_dragon_name, 24);
        assert!(token::uri(new_dragon_token) == new_dragon_uri, 25);

        let maybe_token_royalty = token::royalty(new_dragon_token);
        assert!(option::is_some(&maybe_token_royalty), 26);

        let token_royalty = option::extract(&mut maybe_token_royalty);
        assert!(royalty::denominator(&token_royalty) == 10, 27);
        assert!(royalty::numerator(&token_royalty) == 1, 28);
        assert!(royalty::payee_address(&token_royalty) == resource_account_address, 29);

        let property_map = object::address_to_object<PropertyMap>(new_dragon_address);
        assert!(property_map::read_u64(&property_map, &string::utf8(b"Health")) == 80, 30);
        assert!(property_map::read_u64(&property_map, &string::utf8(b"Defence")) == 6, 31);
        assert!(property_map::read_u64(&property_map, &string::utf8(b"Strength")) == 14, 32);
        assert!(
            property_map::read_string(&property_map, &string::utf8(b"Ability")) == ability_property,
            33
        );
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_hatch_dragon_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let new_dragon_name = string::utf8(b"Baby dragon");
        let new_dragon_description = string::utf8(b"This is a newly born baby dragon!");
        let new_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        hatch_dragon(
            &account,
            11,
            15,
            new_dragon_name,
            new_dragon_description,
            new_dragon_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_hatch_dragon_signer_not_owner_first_monster() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        let first_dragon_address =
            object::create_guid_object_address(resource_account_address, first_creation_number);
        object::transfer_raw(&account, first_dragon_address, @0xABC);

        let new_dragon_name = string::utf8(b"Baby dragon");
        let new_dragon_description = string::utf8(b"This is a newly born baby dragon!");
        let new_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        hatch_dragon(
            &account,
            first_creation_number,
            second_creation_number,
            new_dragon_name,
            new_dragon_description,
            new_dragon_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_hatch_dragon_signer_not_owner_second_monster() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        let second_dragon_address =
            object::create_guid_object_address(resource_account_address, second_creation_number);
        object::transfer_raw(&account, second_dragon_address, @0xABC);

        let new_dragon_name = string::utf8(b"Baby dragon");
        let new_dragon_description = string::utf8(b"This is a newly born baby dragon!");
        let new_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        hatch_dragon(
            &account,
            first_creation_number,
            second_creation_number,
            new_dragon_name,
            new_dragon_description,
            new_dragon_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 9, location = Self)]
    fun test_hatch_dragons_not_breeding() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        let new_dragon_name = string::utf8(b"Baby dragon");
        let new_dragon_description = string::utf8(b"This is a newly born baby dragon!");
        let new_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        hatch_dragon(
            &account,
            first_creation_number,
            second_creation_number,
            new_dragon_name,
            new_dragon_description,
            new_dragon_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 10, location = Self)]
    fun test_hatch_dragon_breeding_not_finished() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);

        let new_dragon_name = string::utf8(b"Baby dragon");
        let new_dragon_description = string::utf8(b"This is a newly born baby dragon!");
        let new_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        hatch_dragon(
            &account,
            first_creation_number,
            second_creation_number,
            new_dragon_name,
            new_dragon_description,
            new_dragon_uri
        );
    }

    #[test]
    fun test_combine_swords() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Sword collection");
        let collection_description = string::utf8(b"This is a sword collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            combine_amount,
            property_values,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);
        let creation_number_brefore_first_creation = account::get_guid_next_creation_num(resource_account_address);

        let sword_name = string::utf8(b"Eggscalibur");
        let sword_description = string::utf8(b"For a true chef");
        let sword_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_sword(&account, collection_name, sword_name, sword_description, sword_uri, 2);

        let creation_number_brefore_second_creation =
            account::get_guid_next_creation_num(resource_account_address);
        let sword_name = string::utf8(b"The Great Spork");
        let sword_description = string::utf8(b"For a true taster");
        let sword_uri =
            string::utf8(b"https://www.watchuseek.com/attachments/spork-notes-1-jpg.532357/");
        create_sword(&account, collection_name, sword_name, sword_description, sword_uri, 2);

        let new_sword_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let new_sword_name = string::utf8(b"Ultimate Cutlery");
        let new_sword_description = string::utf8(b"For a true Gourmet");
        let new_sword_uri = string::utf8(b"https://m.media-amazon.com/images/I/61QyLGqUVQL._AC_UF350,350_QL80_.jpg");
        combine_swords(
            &account,
            collection_name,
            vector[
                creation_number_brefore_first_creation,
                creation_number_brefore_first_creation + 1,
                creation_number_brefore_second_creation,
                creation_number_brefore_second_creation + 1
            ],
            new_sword_name,
            new_sword_description,
            new_sword_uri
        );

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 0, 0);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 1);
        assert!(event::counter(&state.breeder.create_dragon_collection_events) == 0, 2);
        assert!(event::counter(&state.breeder.create_dragon_events) == 0, 3);
        assert!(event::counter(&state.breeder.breed_dragons_events) == 0, 4);
        assert!(event::counter(&state.breeder.hatch_dragon_events) == 0, 5);
        assert!(simple_map::length(&state.combiner.collections) == 1, 6);
        assert!(simple_map::contains_key(&state.combiner.collections, &collection_name), 7);
        assert!(event::counter(&state.combiner.create_sword_collection_events) == 1, 8);
        assert!(event::counter(&state.combiner.create_sword_events) == 2, 9);
        assert!(event::counter(&state.combiner.combine_swords_events) == 1, 10);

        let sword_type = simple_map::borrow(&state.combiner.collections, &collection_name);
        assert!(sword_type.combine_amount == combine_amount, 11);

        let expected_starting_properties = vector::map_ref(&property_values, |value| {
            bcs::to_bytes(value)
        });
        vector::push_back(&mut expected_starting_properties, bcs::to_bytes(&ability_property));
        assert!(sword_type.starting_properties == expected_starting_properties, 12);

        let new_sword_address =
            object::create_guid_object_address(resource_account_address, new_sword_creation_number);
        let new_sword_token = object::address_to_object<Token>(new_sword_address);
        assert!(!aptos_token::are_properties_mutable(new_sword_token), 13);
        assert!(aptos_token::is_burnable(new_sword_token), 14);
        assert!(!aptos_token::is_freezable_by_creator(new_sword_token), 15);
        assert!(!aptos_token::is_mutable_description(new_sword_token), 16);
        assert!(!aptos_token::is_mutable_name(new_sword_token), 17);
        assert!(!aptos_token::is_mutable_uri(new_sword_token), 18);
        assert!(token::creator(new_sword_token) == resource_account_address, 19);
        assert!(token::collection_name(new_sword_token) == collection_name, 20);
        assert!(token::description(new_sword_token) == new_sword_description, 21);
        assert!(token::name(new_sword_token) == new_sword_name, 22);
        assert!(token::uri(new_sword_token) == new_sword_uri, 23);

        let maybe_token_royalty = token::royalty(new_sword_token);
        assert!(option::is_some(&maybe_token_royalty), 24);

        let token_royalty = option::extract(&mut maybe_token_royalty);
        assert!(royalty::denominator(&token_royalty) == 10, 25);
        assert!(royalty::numerator(&token_royalty) == 1, 26);
        assert!(royalty::payee_address(&token_royalty) == resource_account_address, 27);

        let property_map = object::address_to_object<PropertyMap>(new_sword_address);
        assert!(property_map::read_u64(&property_map, &string::utf8(b"Attack")) == 40, 28);
        assert!(property_map::read_u64(&property_map, &string::utf8(b"Durability")) == 20, 30);
        assert!(
            property_map::read_string(&property_map, &string::utf8(b"Ability")) ==
                string::utf8(b"Fire imbued"),
            31
        );
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_combine_swords_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Sword collection");
        let new_sword_name = string::utf8(b"Ultimate Cutlery");
        let new_sword_description = string::utf8(b"For a true Gourmet");
        let new_sword_uri = string::utf8(b"https://m.media-amazon.com/images/I/61QyLGqUVQL._AC_UF350,350_QL80_.jpg");
        combine_swords(
            &account,
            collection_name,
            vector[15, 16, 55, 66],
            new_sword_name,
            new_sword_description,
            new_sword_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 11, location = Self)]
    fun test_combine_swords_incorrect_amount_of_equipment() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Sword collection");
        let collection_description = string::utf8(b"This is a sword collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            combine_amount,
            property_values,
            ability_property
        );

        let new_sword_name = string::utf8(b"Ultimate Cutlery");
        let new_sword_description = string::utf8(b"For a true Gourmet");
        let new_sword_uri = string::utf8(b"https://m.media-amazon.com/images/I/61QyLGqUVQL._AC_UF350,350_QL80_.jpg");
        combine_swords(
            &account,
            collection_name,
            vector[15],
            new_sword_name,
            new_sword_description,
            new_sword_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_combine_swords_signer_does_not_own_token() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Sword collection");
        let collection_description = string::utf8(b"This is a sword collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            combine_amount,
            property_values,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let creation_number = account::get_guid_next_creation_num(resource_account_address);
        let sword_name = string::utf8(b"Eggscalibur");
        let sword_description = string::utf8(b"For a true chef");
        let sword_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_sword(&account, collection_name, sword_name, sword_description, sword_uri, 4);

        let equipment_address =
            object::create_guid_object_address(resource_account_address, creation_number + 1);
        object::transfer_raw(&account, equipment_address, @0xABCDEF);

        let new_sword_name = string::utf8(b"Ultimate Cutlery");
        let new_sword_description = string::utf8(b"For a true Gourmet");
        let new_sword_uri = string::utf8(b"https://m.media-amazon.com/images/I/61QyLGqUVQL._AC_UF350,350_QL80_.jpg");
        combine_swords(
            &account,
            collection_name,
            vector[
                creation_number,
                creation_number + 1,
                creation_number + 2,
                creation_number + 3
            ],
            new_sword_name,
            new_sword_description,
            new_sword_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 13, location = Self)]
    fun test_combine_swords_token_from_incorrect_collection() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Sword collection");
        let collection_description = string::utf8(b"This is a sword collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            combine_amount,
            property_values,
            ability_property
        );

        let another_collection_name = string::utf8(b"Sword collection 2");
        let another_collection_description = string::utf8(b"This is another sword collection");
        let another_collection_uri =
            string::utf8(b"https://i.pinimg.com/originals/07/6b/b1/076bb1fbef7d70f0a1a961ab8c136a22.jpg");
        let another_combine_amount = 4;
        let another_property_values = vector[10, 5];
        let another_ability_property = string::utf8(b"Ice imbued");
        create_sword_collection(
            &account,
            another_collection_name,
            another_collection_description,
            another_collection_uri,
            another_combine_amount,
            another_property_values,
            another_ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let creation_number = account::get_guid_next_creation_num(resource_account_address);
        let sword_name = string::utf8(b"Eggscalibur");
        let sword_description = string::utf8(b"For a true chef");
        let sword_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_sword(&account, collection_name, sword_name, sword_description, sword_uri, 3);

        let sword_name = string::utf8(b"Eggscalibur");
        let sword_description = string::utf8(b"For a true chef");
        let sword_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_sword(&account, another_collection_name, sword_name, sword_description, sword_uri, 1);

        let new_sword_name = string::utf8(b"Ultimate Cutlery");
        let new_sword_description = string::utf8(b"For a true Gourmet");
        let new_sword_uri = string::utf8(b"https://m.media-amazon.com/images/I/61QyLGqUVQL._AC_UF350,350_QL80_.jpg");
        combine_swords(
            &account,
            collection_name,
            vector[
                creation_number,
                creation_number + 3,
                creation_number + 2,
                creation_number + 1
            ],
            new_sword_name,
            new_sword_description,
            new_sword_uri
        );
    }
}