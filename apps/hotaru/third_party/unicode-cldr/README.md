# Unicode CLDR territory names

`lib/common/country_names.dart` contains two-letter territory names from Unicode
CLDR JSON **46.1.0**, in the seven application languages. These are display names,
not evidence of IP registration, physical location or native/broadcast status.

Source: https://github.com/unicode-org/cldr-json/tree/46.1.0/cldr-json/cldr-localenames-full/main

The license is bundled with both platform packages as an application asset.

License: [Unicode License V3](../../assets/data/Unicode-CLDR-LICENSE.txt).

To regenerate, download `territories.json` for `en`, `zh`, `ja`, `ru`, `fr`, `es`
and `ko` from the versioned source into a directory as `<language>.json`, then
run from `apps/hotaru`:

```
dart run tool/generate_country_names.dart /path/to/cldr-files
```
