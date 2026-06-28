# RULE: use the Linux toolchain (WSL)

A Windows Ruby on `/mnt/c/...` shadows the Linux `ruby`/`rake`. Before ANY build
or `ruby`/`rake`/generator command, strip `/mnt/c` from PATH:

```sh
CLEANPATH=$(echo "$PATH" | tr ':' '\n' | grep -v '^/mnt/c' | paste -sd:); export PATH=$CLEANPATH
```

`vendor/mruby/minirake` is just `exec "rake"` — a real `rake` gem must be
installed for the Linux Ruby (`gem install rake`).
