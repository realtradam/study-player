# Study Player Makefile
# Default target: Linux native (gcc)
#   make windows  - Cross-compile for Windows (MinGW)
#   make clean    - Remove build artifacts
#
# Builds raylib from source as a static library, then links the application.

# Directories
SRC_DIR     := src
BUILD_DIR   := build
RAYLIB_SRC  := deps/raylib/src
RAYLIB_LIB  := $(BUILD_DIR)/libraylib.a

# Application source files (auto-discovered)
SRCS        := $(wildcard $(SRC_DIR)/*.c)
APP_OBJS    := $(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/%.o,$(SRCS))

# Raylib source files
RAYLIB_SRCS := $(RAYLIB_SRC)/rcore.c $(RAYLIB_SRC)/rshapes.c $(RAYLIB_SRC)/rtextures.c \
               $(RAYLIB_SRC)/rtext.c $(RAYLIB_SRC)/rmodels.c $(RAYLIB_SRC)/raudio.c \
               $(RAYLIB_SRC)/rglfw.c
RAYLIB_OBJS := $(patsubst $(RAYLIB_SRC)/%.c,$(BUILD_DIR)/raylib/%.o,$(RAYLIB_SRCS))

# Common include paths
COMMON_INCS := -I$(BUILD_DIR) -I$(RAYLIB_SRC) -I$(RAYLIB_SRC)/external/glfw/include -Ideps/raygui/src

# ---------------------------------------------------------------------------
# Linux native configuration (default target)
# ---------------------------------------------------------------------------
CC_LINUX    := gcc
APP_OUT     := $(BUILD_DIR)/study-player
DEFINES_LINUX := -DPLATFORM_DESKTOP -DPLATFORM_LINUX -D_GLFW_X11
LDFLAGS_LINUX := -lm -lrt -ldl -lpthread -lX11

# ---------------------------------------------------------------------------
# Windows cross-compile configuration
# ---------------------------------------------------------------------------
CC_WIN      := x86_64-w64-mingw32-gcc
APP_OUT_WIN := $(BUILD_DIR)/study-player.exe
DEFINES_WIN := -DPLATFORM_DESKTOP -D_GLFW_WIN32
LDFLAGS_WIN := -lgdi32 -lwinmm -lcomdlg32 -lole32

# CFLAGS
CFLAGS_COMMON := -std=c99 -O2 $(COMMON_INCS)
CFLAGS_APP    := $(CFLAGS_COMMON) -Wall -Wextra
CFLAGS_RAYLIB := $(CFLAGS_COMMON) -w

# ---------------------------------------------------------------------------
# Font header
# ---------------------------------------------------------------------------
FONT_HEADER := $(BUILD_DIR)/font_data.h

.PHONY: all windows clean

# ---------------------------------------------------------------------------
# Default target: Linux native
# ---------------------------------------------------------------------------
all: CC := $(CC_LINUX)
all: AR := ar
all: DEFINES := $(DEFINES_LINUX)
all: LDFLAGS := $(LDFLAGS_LINUX)
all: $(FONT_HEADER) $(APP_OUT)

# ---------------------------------------------------------------------------
# Windows cross-compile
# ---------------------------------------------------------------------------
windows: CC := $(CC_WIN)
windows: AR := x86_64-w64-mingw32-ar
windows: DEFINES := $(DEFINES_WIN)
windows: LDFLAGS := $(LDFLAGS_WIN)
windows: $(FONT_HEADER) $(APP_OUT_WIN)

# ---------------------------------------------------------------------------
# Link rules
# ---------------------------------------------------------------------------
# Direct static link of raylib .a (no -lraylib to avoid picking up shared lib)
$(APP_OUT) $(APP_OUT_WIN): $(APP_OBJS) $(RAYLIB_LIB) | $(BUILD_DIR)
	$(CC) $(CFLAGS_APP) $(DEFINES) -o $@ $(APP_OBJS) $(RAYLIB_LIB) $(LDFLAGS)

$(RAYLIB_LIB): $(RAYLIB_OBJS) | $(BUILD_DIR)
	$(AR) rcs $@ $^

# ---------------------------------------------------------------------------
# Compile rules
# ---------------------------------------------------------------------------
$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c $(FONT_HEADER) | $(BUILD_DIR)
	$(CC) $(CFLAGS_APP) $(DEFINES) -c -o $@ $<

$(BUILD_DIR)/raylib/%.o: $(RAYLIB_SRC)/%.c | $(BUILD_DIR)/raylib
	$(CC) $(CFLAGS_RAYLIB) $(DEFINES) -c -o $@ $<

# ---------------------------------------------------------------------------
# Font header generation (best-effort)
# ---------------------------------------------------------------------------
# Discovers the first .otf/.ttf in resources/ at shell-level to handle
# spaces in filenames.  Uses xxd if available; otherwise creates a stub.
$(FONT_HEADER): | $(BUILD_DIR)
	@FONT_FILE="$$(find resources -maxdepth 1 -type f \( -iname '*.otf' -o -iname '*.ttf' \) -print -quit 2>/dev/null)"; \
	if command -v xxd >/dev/null 2>&1 && [ -n "$$FONT_FILE" ]; then \
		echo "  XXD    $$(basename "$$FONT_FILE") -> $@"; \
		xxd -i "$$FONT_FILE" > "$@.tmp"; \
		VARNAME=$$(grep -oP 'unsigned char \K[a-zA-Z0-9_]+' "$@.tmp" | head -1); \
		sed -i "s/$${VARNAME}/embedded_font_data/g" "$@.tmp"; \
		echo '#define FONT_EMBEDDED 1' >> "$@.tmp"; \
		mv "$@.tmp" "$@"; \
	elif [ -n "$$FONT_FILE" ]; then \
		echo "  WARN   xxd not available, using stub font header"; \
		printf '/* No font embedded - xxd not available */\nstatic unsigned char embedded_font_data[] = {0};\nstatic unsigned int embedded_font_data_len = 0;\n#define FONT_EMBEDDED 0\n' > "$@"; \
	else \
		echo "  INFO   No font file found, using default raylib font"; \
		printf '/* No font embedded - no font file */\nstatic unsigned char embedded_font_data[] = {0};\nstatic unsigned int embedded_font_data_len = 0;\n#define FONT_EMBEDDED 0\n' > "$@"; \
	fi

# ---------------------------------------------------------------------------
# Directory creation
# ---------------------------------------------------------------------------
$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/raylib:
	mkdir -p $(BUILD_DIR)/raylib

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------
clean:
	rm -rf $(BUILD_DIR)
