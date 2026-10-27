-- init.lua - ALDI Price Browser for Minetest
-- Browse ALDI US product prices in-game

local modname = minetest.get_current_modname()
local modpath = minetest.get_modpath(modname)

-- Request HTTP API (must be whitelisted in minetest.conf)
local http = minetest.request_http_api()

-- Request insecure environment for cookie management (curl)
-- Requires: secure.trusted_mods = aldi_browser in minetest.conf
local insecure_env = minetest.request_insecure_environment()

-- Load modules
local api = dofile(modpath .. "/api.lua")(http, insecure_env)
local formspec = dofile(modpath .. "/formspec.lua")

-- Get mod storage for persistence
local storage = minetest.get_mod_storage()

-- Player context storage
local player_context = {}

-- Initialize or get player context
local function get_context(player_name)
    if not player_context[player_name] then
        -- Try to load from mod storage
        local stored_shop_id = storage:get_string(player_name .. "_shop_id")
        local stored_session_token = storage:get_string(player_name .. "_session_token")
        local stored_store_city = storage:get_string(player_name .. "_store_city")
        local stored_store_address = storage:get_string(player_name .. "_store_address")
        local stored_zip = storage:get_string(player_name .. "_zip")
        local stored_location_id = storage:get_string(player_name .. "_location_id")

        player_context[player_name] = {
            shop_id = stored_shop_id ~= "" and stored_shop_id or nil,
            session_token = stored_session_token ~= "" and stored_session_token or nil,
            location_id = stored_location_id ~= "" and stored_location_id or nil,
            store_city = stored_store_city ~= "" and stored_store_city or nil,
            store_address = stored_store_address ~= "" and stored_store_address or nil,
            zip = stored_zip ~= "" and stored_zip or nil,
            current_page = "main",
            search_query = "",
            search_results = nil,
            category_results = nil,
            categories = nil,
            selected_category = nil,
            selected_product_index = 1,
            offset = 0,
            loading = false,
            error_msg = nil,
        }
    end
    return player_context[player_name]
end

-- Save store selection to mod storage
local function save_store(player_name, ctx)
    if ctx.shop_id then
        storage:set_string(player_name .. "_shop_id", ctx.shop_id)
        storage:set_string(player_name .. "_session_token", ctx.session_token or "")
        storage:set_string(player_name .. "_store_city", ctx.store_city or "")
        storage:set_string(player_name .. "_store_address", ctx.store_address or "")
        storage:set_string(player_name .. "_zip", ctx.zip or "")
        storage:set_string(player_name .. "_location_id", ctx.location_id or "")
    end
end

-- Show formspec to player based on current page
local function show_formspec(player_name)
    local ctx = get_context(player_name)
    local fs

    if ctx.current_page == "main" then
        fs = formspec.main_menu(ctx)
    elseif ctx.current_page == "search" then
        fs = formspec.product_search(ctx, ctx.search_results)
    elseif ctx.current_page == "category" then
        fs = formspec.category_browser(ctx, ctx.categories, ctx.category_results)
    elseif ctx.current_page == "detail" then
        local product = nil
        local results = ctx.search_results or ctx.category_results
        if results and results.products and ctx.selected_product_index then
            product = results.products[ctx.selected_product_index]
        end
        fs = formspec.product_detail(ctx, product)
    else
        fs = formspec.main_menu(ctx)
    end

    minetest.show_formspec(player_name, "aldi_browser:main", fs)
end

-- Handle formspec input
minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "aldi_browser:main" then
        return false
    end

    local player_name = player:get_player_name()
    local ctx = get_context(player_name)

    -- Clear error message on any interaction
    ctx.error_msg = nil

    -- Close button
    if fields.close or fields.quit then
        return true
    end

    -- Back button - return to main or previous page
    if fields.back then
        if ctx.current_page == "detail" then
            if ctx.category_results then
                ctx.current_page = "category"
            else
                ctx.current_page = "search"
            end
        else
            ctx.current_page = "main"
        end
        show_formspec(player_name)
        return true
    end

    -- Main menu: Find store button
    if fields.find_store then
        local zip = fields.zip
        if not zip or zip == "" then
            ctx.error_msg = "Please enter a ZIP code"
            show_formspec(player_name)
            return true
        end

        if not zip:match("^%d%d%d%d%d$") then
            ctx.error_msg = "Invalid ZIP code (must be 5 digits)"
            show_formspec(player_name)
            return true
        end

        ctx.zip = zip
        ctx.loading = true
        show_formspec(player_name)

        api.find_store(zip, function(store_info, err)
            ctx.loading = false
            if err then
                ctx.error_msg = err
                show_formspec(player_name)
                return
            end

            ctx.shop_id = store_info.shop_id
            ctx.session_token = store_info.session_token
            ctx.location_id = store_info.location_id
            ctx.store_city = store_info.city_state
            ctx.store_address = store_info.address
            ctx.categories = nil  -- Reset categories for new store
            save_store(player_name, ctx)
            ctx.current_page = "main"
            show_formspec(player_name)
        end)
        return true
    end

    -- Main menu: Search products button
    if fields.search_products then
        if not ctx.shop_id then
            ctx.error_msg = "Please select a store first"
            show_formspec(player_name)
            return true
        end
        ctx.current_page = "search"
        ctx.search_results = nil
        ctx.offset = 0
        ctx.selected_product_index = 1
        show_formspec(player_name)
        return true
    end

    -- Main menu: Browse categories button
    if fields.browse_categories then
        if not ctx.shop_id then
            ctx.error_msg = "Please select a store first"
            show_formspec(player_name)
            return true
        end
        ctx.current_page = "category"
        ctx.category_results = nil
        ctx.offset = 0
        ctx.selected_product_index = 1

        -- Load categories if not already loaded
        if not ctx.categories then
            ctx.loading = true
            show_formspec(player_name)

            api.get_categories(ctx.shop_id, ctx.session_token, function(categories, err, new_token)
                ctx.loading = false
                if err then
                    ctx.error_msg = err
                else
                    ctx.categories = categories
                    if new_token then
                        ctx.session_token = new_token
                    end
                    if #categories > 0 then
                        ctx.selected_category = categories[1].slug
                    end
                end
                show_formspec(player_name)
            end)
        else
            show_formspec(player_name)
        end
        return true
    end

    -- Search page: Do search button
    if fields.do_search or (fields.key_enter_field == "search_query") then
        local query = fields.search_query or ""
        ctx.search_query = query
        ctx.offset = 0
        ctx.selected_product_index = 1
        ctx.loading = true
        show_formspec(player_name)

        api.search_products(ctx.shop_id, ctx.session_token, query, 0, 24, function(results, err)
            ctx.loading = false
            if err then
                ctx.error_msg = err
                ctx.search_results = nil
            else
                ctx.search_results = results
                if results.session_token then
                    ctx.session_token = results.session_token
                end
            end
            show_formspec(player_name)
        end)
        return true
    end

    -- Product list selection - only return if actual list interaction
    if fields.product_list then
        local event = minetest.explode_textlist_event(fields.product_list)
        if event.type == "CHG" or event.type == "DCL" then
            ctx.selected_product_index = event.index
            if event.type == "DCL" then
                ctx.current_page = "detail"
                show_formspec(player_name)
            end
            return true
        end
    end

    -- View detail button
    if fields.view_detail then
        local results = ctx.search_results or ctx.category_results
        if results and results.products and #results.products > 0 then
            ctx.current_page = "detail"
        end
        show_formspec(player_name)
        return true
    end

    -- Category selection dropdown - update selected_category but don't return
    if fields.category_select and ctx.categories then
        for _, cat in ipairs(ctx.categories) do
            if fields.category_select == cat.name then
                ctx.selected_category = cat.slug
                break
            end
        end
    end

    -- Load category button
    if fields.load_category then
        if fields.category_select and ctx.categories then
            for _, cat in ipairs(ctx.categories) do
                if fields.category_select == cat.name then
                    ctx.selected_category = cat.slug
                    break
                end
            end
        end

        if not ctx.selected_category then
            ctx.error_msg = "Please select a category first"
            show_formspec(player_name)
            return true
        end
        ctx.offset = 0
        ctx.selected_product_index = 1
        ctx.loading = true
        show_formspec(player_name)

        api.search_by_category(ctx.shop_id, ctx.session_token, ctx.selected_category, 0, 24, function(results, err)
            ctx.loading = false
            if err then
                ctx.error_msg = err
                ctx.category_results = nil
            else
                ctx.category_results = results
                if results.session_token then
                    ctx.session_token = results.session_token
                end
            end
            show_formspec(player_name)
        end)
        return true
    end

    -- Pagination: Previous page
    if fields.prev_page then
        local results = ctx.search_results or ctx.category_results
        if results and results.offset > 0 then
            local new_offset = math.max(0, results.offset - results.limit)
            ctx.loading = true
            ctx.selected_product_index = 1
            show_formspec(player_name)

            if ctx.current_page == "search" then
                api.search_products(ctx.shop_id, ctx.session_token, ctx.search_query, new_offset, 24, function(new_results, err)
                    ctx.loading = false
                    if err then
                        ctx.error_msg = err
                    else
                        ctx.search_results = new_results
                        if new_results.session_token then
                            ctx.session_token = new_results.session_token
                        end
                    end
                    show_formspec(player_name)
                end)
            elseif ctx.current_page == "category" and ctx.selected_category then
                api.search_by_category(ctx.shop_id, ctx.session_token, ctx.selected_category, new_offset, 24, function(new_results, err)
                    ctx.loading = false
                    if err then
                        ctx.error_msg = err
                    else
                        ctx.category_results = new_results
                        if new_results.session_token then
                            ctx.session_token = new_results.session_token
                        end
                    end
                    show_formspec(player_name)
                end)
            end
        end
        return true
    end

    -- Pagination: Next page
    if fields.next_page then
        local results = ctx.search_results or ctx.category_results
        if results then
            local new_offset = results.offset + results.limit
            if new_offset < results.total_count then
                ctx.loading = true
                ctx.selected_product_index = 1
                show_formspec(player_name)

                if ctx.current_page == "search" then
                    api.search_products(ctx.shop_id, ctx.session_token, ctx.search_query, new_offset, 24, function(new_results, err)
                        ctx.loading = false
                        if err then
                            ctx.error_msg = err
                        else
                            ctx.search_results = new_results
                            if new_results.session_token then
                                ctx.session_token = new_results.session_token
                            end
                        end
                        show_formspec(player_name)
                    end)
                elseif ctx.current_page == "category" and ctx.selected_category then
                    api.search_by_category(ctx.shop_id, ctx.session_token, ctx.selected_category, new_offset, 24, function(new_results, err)
                        ctx.loading = false
                        if err then
                            ctx.error_msg = err
                        else
                            ctx.category_results = new_results
                            if new_results.session_token then
                                ctx.session_token = new_results.session_token
                            end
                        end
                        show_formspec(player_name)
                    end)
                end
            end
        end
        return true
    end

    return true
end)

-- Register chat commands
minetest.register_chatcommand("aldi", {
    params = "[search <term>] | [store <zip>]",
    description = "Open ALDI price browser",
    func = function(name, param)
        -- Check if HTTP API is available
        if not http then
            minetest.show_formspec(name, "aldi_browser:main", formspec.http_error())
            return true, "HTTP access required. Add 'aldi_browser' to secure.http_mods in minetest.conf"
        end

        local ctx = get_context(name)

        -- Parse subcommands
        local cmd, arg = param:match("^(%S+)%s*(.*)$")

        if cmd == "search" and arg and arg ~= "" then
            -- Quick search
            if not ctx.shop_id then
                return false, "No store selected. Use /aldi to set one first."
            end
            ctx.current_page = "search"
            ctx.search_query = arg
            ctx.offset = 0
            ctx.selected_product_index = 1
            ctx.loading = true
            show_formspec(name)

            api.search_products(ctx.shop_id, ctx.session_token, arg, 0, 24, function(results, err)
                ctx.loading = false
                if err then
                    ctx.error_msg = err
                    ctx.search_results = nil
                else
                    ctx.search_results = results
                    if results.session_token then
                        ctx.session_token = results.session_token
                    end
                end
                show_formspec(name)
            end)
            return true, "Searching for: " .. arg

        elseif cmd == "store" and arg and arg ~= "" then
            -- Change store by ZIP
            if not arg:match("^%d%d%d%d%d$") then
                return false, "Invalid ZIP code (must be 5 digits)"
            end
            ctx.zip = arg
            ctx.loading = true

            api.find_store(arg, function(store_info, err)
                ctx.loading = false
                if err then
                    minetest.chat_send_player(name, "Error: " .. err)
                    return
                end

                ctx.shop_id = store_info.shop_id
                ctx.session_token = store_info.session_token
                ctx.location_id = store_info.location_id
                ctx.store_city = store_info.city_state
                ctx.store_address = store_info.address
                ctx.categories = nil
                save_store(name, ctx)
                ctx.current_page = "main"

                local msg = "Store set: ALDI"
                if store_info.city_state and store_info.city_state ~= "" then
                    msg = msg .. " near " .. store_info.city_state
                end
                if store_info.address then
                    msg = msg .. " (" .. store_info.address .. ")"
                end
                minetest.chat_send_player(name, msg)
                show_formspec(name)
            end)
            return true, "Finding ALDI store near ZIP: " .. arg

        else
            -- Open main menu
            ctx.current_page = "main"
            show_formspec(name)
            return true
        end
    end,
})

-- Log successful load
if http then
    if insecure_env then
        minetest.log("action", "[aldi_browser] Loaded with HTTP + insecure env (cookie support enabled)")
    else
        minetest.log("warning", "[aldi_browser] Loaded with HTTP but WITHOUT insecure env. " ..
                     "Cookie auth will fail. Add 'aldi_browser' to secure.trusted_mods in minetest.conf")
    end
else
    minetest.log("warning", "[aldi_browser] HTTP access not available. " ..
                 "Add 'aldi_browser' to secure.http_mods AND secure.trusted_mods in minetest.conf")
end
