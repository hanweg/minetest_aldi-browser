# ALDI Price Browser for Minetest

Browse ALDI US product prices in-game via a formspec interface.

## Installation

1. Copy the `aldi_browser` folder to your Minetest mods directory:
   - Linux: `~/.minetest/mods/`
   - Windows: `C:\Users\<name>\minetest\mods\`
   - macOS: `~/Library/Application Support/minetest/mods/`

2. **Enable HTTP access and trusted mod status** (both required). Add these lines to your `minetest.conf`:
   ```
   secure.http_mods = aldi_browser
   secure.trusted_mods = aldi_browser
   ```
   If you have other mods listed, separate them with commas:
   ```
   secure.http_mods = aldi_browser,other_mod
   secure.trusted_mods = aldi_browser,other_mod
   ```

3. **Ensure `curl` is installed** on your system. It is used to obtain session cookies from the ALDI storefront.

4. Enable the mod in the game settings when creating or loading a world.

## Usage

### Chat Commands

- `/aldi` - Open the main browser interface
- `/aldi search <term>` - Quick search for products (requires store to be set)
- `/aldi store <zip>` - Find and select a store by ZIP code

### Interface

**Main Menu:**
- Enter a ZIP code and click "Find Store" to locate your nearest ALDI
- Once a store is set, use "Search Products" or "Browse Categories"

**Product Search:**
- Enter a search term and press Enter or click "Search"
- Results show product name, brand, price, unit price, and sale/stock status
- Use Prev/Next buttons to paginate through results
- Double-click a product or click "View Details" for more info

**Category Browser:**
- Select a department from the dropdown (Produce, Dairy, Frozen, etc.)
- Click "Load Category" to view products
- Navigate with pagination buttons

### Tips

- Your store selection is saved and persists across sessions
- Double-click items in lists for quick selection
- Products on sale show the original "Was" price
- Out-of-stock items are marked [OUT OF STOCK]

## Troubleshooting

**"HTTP API not available" or "Configuration Required" error:**
- Make sure both `secure.http_mods` and `secure.trusted_mods` include `aldi_browser` in minetest.conf
- Restart Minetest after editing the config

**"Could not obtain session cookie":**
- Verify `curl` is installed (`curl --version` in a terminal)
- Verify `aldi_browser` is in `secure.trusted_mods` in minetest.conf
- If `secure.enable_security = false`, both settings above should still be present

**"No ALDI store found":**
- Verify the ZIP code is valid (5 digits)
- Try a nearby ZIP code

**"HTTP request failed":**
- Check your internet connection
- The ALDI/Instacart API may be temporarily unavailable

## Technical Details

This mod fetches data from the ALDI US storefront, which is powered by Instacart's GraphQL API at `https://www.aldi.us/graphql`. Persisted queries are used for all operations.

A session cookie (`__Host-instacart_sid`) is required for authenticated queries and is obtained via `curl` from the storefront page. The cookie is cached and refreshed every 5 minutes.

### Why `secure.trusted_mods`?

Minetest's `http.fetch` does not expose HTTP response headers, so the `Set-Cookie` header from the storefront cannot be read directly. The mod uses `io.popen` (which requires trusted mod status) to run `curl` with cookie jar output to obtain the session cookie.

## License

MIT License
