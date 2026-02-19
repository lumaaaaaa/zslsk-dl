# zslsk-dl

zslsk-dl is a CLI frontend for the [zslsk](https://github.com/lumaaaaaa/zslsk) Soulseek library providing a simple interactive download interface.

The tool is designed to be used to download music to a root library directory, allowing customization of the output path structure via format templates.

> [!CAUTION]
> This program uses zslsk, an immature Zig-based Soulseek library which is currently not intended for use in production. There are likely vulnerabilities
> that exist in the library's codebase that may put your system at risk.

## Configuration

By default, zslsk-dl looks for a config file at `~/.config/zslsk-dl/config.zon`. If no config file is found, you will be prompted for credentials on
every run and default config values will be used.

An example config is provided below:

```zon
.{
  // credentials (if provided will skip interactive authentication)
  .username = "user",
  .password = "pass",

  // library configuration
  .library_dir = "/home/devin/Music/",        // root of music library (default = ".")
  .path_format = "{artist}/[{year}] {album}", // subpath formatting    (default = same)
}
```
