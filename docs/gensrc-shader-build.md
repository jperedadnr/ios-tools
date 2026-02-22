# JavaFX Graphics Shader Generation Build Process

## Overview

The `Gensrc.gmk` makefile manages the generation of JavaFX graphics shaders during the gensrc phase of the OpenJDK build. This document explains the complex multi-step process required to compile shader sources from JSL (Java Shader Language) files into platform-specific shader implementations.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Build Flow Diagram](#build-flow-diagram)
3. [Step-by-Step Process](#step-by-step-process)
4. [Critical Dependencies](#critical-dependencies)
5. [Execution Order Guarantees](#execution-order-guarantees)
6. [Common Issues and Solutions](#common-issues-and-solutions)

---

## Architecture Overview

The shader generation process involves multiple stages:

1. **Temp Core Class Compilation**: Compile javafx.base and javafx.graphics to a temporary location
2. **Parser Generation**: Generate ANTLR parser for JSL grammar
3. **Compiler Compilation**: Compile the shader compiler tools (JSLC, Decora, Prism)
4. **Shader Generation**: Generate shader sources in multiple formats (GLSL, HLSL, Metal)
5. **Native Compilation**: Compile Metal shaders to native .air and .metallib formats (macOS), or HLSL shaders to .obj files (Windows)
6. **Flattening**: Copy generated sources (including .obj) to final gensrc output directory

### Key Challenge

The shader compilers need classes from javafx.graphics to compile, but javafx.graphics itself needs the generated shaders to compile. This circular dependency is resolved by compiling core classes to a **temporary location** first.

### Cross-Platform Support

The build system supports **Windows, macOS, and Linux**:

- **Path Separators**: Always use `:` (colon); `fixpath` converts to `;` on Windows when needed
- **Platform-Specific Shaders**:
  - Metal shaders (`.metal` → `.air` → `.metallib`) compiled only on macOS
  - DirectX shaders (`.hlsl` → `.obj`) compiled only on Windows
  - OpenGL shaders (`.glsl`, `.frag`) compiled on all platforms

### ANTLR Jar

`antlr-4.13.2-complete.jar` is expected to be **pre-placed** at `make/data/javafx-tools/antlr-4.13.2-complete.jar` — it is **not downloaded** at build time. The script that clones/prepares the jfx repository is responsible for copying this jar from `openjdk-ext/src/make/data/javafx-tools/`.

---

## Build Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                    JAVAFX GRAPHICS GENSRC PHASE                     │
└─────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│ STEP 0: Compile Temp Core Classes                                    │
├──────────────────────────────────────────────────────────────────────┤
│ VersionInfo.java                                                     │
│       │                                                              │
│       ▼                                                              │
│ BUILD_BASE_CORE_TEMP ────────────► temp-modules/javafx.base/         │
│  (311 classes)                      - javafx.beans.*                 │
│                                     - javafx.collections.*           │
│       │                             - com.sun.javafx.*               │
│       ▼                                                              │
│ BUILD_GRAPHICS_CORE_TEMP ──────► temp-modules/javafx.graphics/       │
│  (1,563 classes)                    - com.sun.scenario.effect.*      │
│                                     - com.sun.javafx.*               │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 1: Generate ANTLR Parser (ANTLR jar pre-placed)                 │
├──────────────────────────────────────────────────────────────────────┤
│ make/data/javafx-tools/antlr-4.13.2-complete.jar (pre-placed)        │
│       │                                                              │
│       ▼                                                              │
│ Generate parser from JSL.g4 grammar ──► antlr/*.java                 │
│  - JSLLexer.java                                                     │
│  - JSLParser.java                                                    │
│  - JSLListener.java                                                  │
│  - JSLVisitor.java                                                   │
│  - JSLBaseListener.java                                              │
│  - JSLBaseVisitor.java                                               │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 2: Compile JSLC Compiler                                        │
├──────────────────────────────────────────────────────────────────────┤
│ BUILD_JSLC_COMPILER                                                  │
│  Input: src/jslc/java/*.java + antlr/*.java                          │
│  Output: classes/java/jslc/*.class                                   │
│  Classpath: antlr-4.13.2-complete.jar                                │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 3: Compile Decora Shader Compilers                              │
├──────────────────────────────────────────────────────────────────────┤
│ BUILD_DECORA_COMPILERS                                               │
│  Input: src/main/jsl-decora/*.java                                   │
│  Output: classes/jsl-compilers/decora/*.class                        │
│  Classpath: JSLC + ANTLR + temp javafx.graphics (for Effect classes) │
│  Dependencies: BUILD_JSLC_COMPILER, BUILD_GRAPHICS_CORE_TEMP         │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 4: Generate Decora Shaders                                      │
├──────────────────────────────────────────────────────────────────────┤
│ GenAllDecoraShaders (runs CompileBlend, CompilePhong, etc.)          │
│  Input: src/main/jsl-decora/*.jsl                                    │
│  Output: jsl-decora-temp/com/sun/scenario/effect/impl/               │
│    ├─ sw/java/*.java          (Software renderer)                    │
│    ├─ sw/sse/*.java            (SSE optimized)                       │
│    ├─ prism/ps/*.java          (Prism pipeline)                      │
│    ├─ hw/d3d/hlsl/*.hlsl       (DirectX shaders)    [Windows]        │
│    └─ hw/mtl/msl/*.metal       (Metal shaders)      [macOS]          │
│                                                                      │
│ Marker: .decora_shaders.marker                                       │
└──────────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴────────────────┐
              │ (Windows only)                  │
              ▼                                 ▼
┌─────────────────────────┐    ┌──────────────────────────────────────┐
│ STEP 5b: Compile Decora │    │ STEP 5: Flatten Decora Shaders       │
│ HLSL shaders (Windows)  │    │ (waits for 5b on Windows)            │
├─────────────────────────┤    ├──────────────────────────────────────┤
│ FXC /T ps_3_0           │    │ Copy jsl-decora-temp/com →           │
│ *.hlsl → *.obj          │    │   gensrc/javafx.graphics/com/        │
│ (into jsl-decora-temp)  │    │ .obj files are copied here too!      │
│                         │    │                                      │
│ Marker: .decora_hlsl    │    │ Marker: .shaders_flattened           │
│         .marker         │    └──────────────────────────────────────┘
└─────────────────────────┘                     │
              │                                 │
              └─────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 5a: Compile Decora Metal Shaders (macOS only)                   │
├──────────────────────────────────────────────────────────────────────┤
│ Compile each .metal file sequentially:                               │
│   xcrun metal -I mtl-headers *.metal → *.air                         │
│                                                                      │
│ ⚠️  CRITICAL: This step creates DecoraShaderCommon.h (1,267 lines)   │
│     as a side effect when compiling the first Decora Metal shader!   │
│                                                                      │
│ Output: msl/Decora/*.air (93 files)                                  │
│ Output: mtl-headers/DecoraShaderCommon.h (1,267 lines)               │
│ Output: mtl-headers/FragmentShaderCommon.h (1,329 lines)             │
│                                                                      │
│ Marker: _decora_msl.marker                                           │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 6: Compile Prism Shader Compilers                               │
├──────────────────────────────────────────────────────────────────────┤
│ BUILD_PRISM_COMPILERS                                                │
│  Input: src/main/jsl-prism/*.java                                    │
│  Output: classes/jsl-compilers/prism/*.class                         │
│  Classpath: JSLC + ANTLR + temp javafx.graphics                      │
│  Dependencies: BUILD_JSLC_COMPILER, BUILD_GRAPHICS_CORE_TEMP         │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 7: Generate Prism Shaders                                       │
├──────────────────────────────────────────────────────────────────────┤
│ ⚠️  CRITICAL: Sequential for loop prevents header corruption!        │
│                                                                      │
│ For each .jsl file (SEQUENTIALLY):                                   │
│   CompileJSL *.jsl → multiple shader variants                        │
│                                                                      │
│ Output: jsl-prism-temp/com/sun/prism/                                │
│   ├─ d3d/hlsl/*.hlsl         (DirectX shaders)    [Windows]          │
│   ├─ es2/gl/*.glsl           (OpenGL ES 2.0 shaders)                 │
│   └─ mtl/msl/*.metal         (Metal shaders)      [macOS]            │
│                                                                      │
│ ⚠️  Each CompileJSL invocation APPENDS to PrismShaderCommon.h        │
│     Must run sequentially to avoid corruption!                       │
│                                                                      │
│ Marker: .prism_shaders.marker                                        │
└──────────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴─────────────────┐
              │ (Windows only)                  │
              ▼                                 ▼
┌─────────────────────────┐    ┌──────────────────────────────────────┐
│ STEP 8b: Compile Prism  │    │ STEP 8: Flatten Prism Shaders        │
│ HLSL shaders (Windows)  │    │ (waits for 8b on Windows)            │
├─────────────────────────┤    ├──────────────────────────────────────┤
│ FXC /T ps_3_0           │    │ Copy jsl-prism-temp/com →            │
│ *.hlsl → *.obj          │    │   gensrc/javafx.graphics/com/        │
│ (into jsl-prism-temp)   │    │ .obj files are copied here too!      │
│                         │    │                                      │
│ Marker: .prism_hlsl     │    │ Marker: .prism_flattened             │
│         .marker         │    └──────────────────────────────────────┘
└─────────────────────────┘                     │
              │                                 │
              └─────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 8a: Compile Prism Metal Shaders (macOS only)                    │
├──────────────────────────────────────────────────────────────────────┤
│ Compile each .metal file sequentially:                               │
│   xcrun metal -I mtl-headers *.metal → *.air                         │
│                                                                      │
│ ⚠️  CRITICAL: This step UPDATES PrismShaderCommon.h to full size!    │
│     Final size: 9,982 lines                                          │
│                                                                      │
│ Output: msl/Prism/*.air (multiple files)                             │
│ Output: mtl-headers/PrismShaderCommon.h (9,982 lines - COMPLETE!)    │
│                                                                      │
│ Marker: _prism_msl.marker                                            │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 9: Compile and Link Native Metal Shaders (macOS only)           │
├──────────────────────────────────────────────────────────────────────┤
│ Compile built-in Metal shaders from native-prism-mtl/msl/            │
│   xcrun metal *.metal → *.air                                        │
│                                                                      │
│ Marker: _native_msl.marker                                           │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 9 (link): Link Metal Library (macOS only)                       │
├──────────────────────────────────────────────────────────────────────┤
│ Link all .air files into single metallib:                            │
│   xcrun metallib *.air → jfxshaders.metallib                         │
│                                                                      │
│ Output: msl/com/sun/prism/mtl/msl/jfxshaders.metallib                │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 10: Copy metallib to Final Location (macOS only)                │
├──────────────────────────────────────────────────────────────────────┤
│ Copy to gensrc output for inclusion in module                        │
│ Output: gensrc/javafx.graphics/com/sun/prism/mtl/msl/*.metallib      │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ FINAL MARKER: .headers_ready (macOS only)                            │
├──────────────────────────────────────────────────────────────────────┤
│ Created after all shader generation and Metal compilation complete   │
│ Used by Lib.gmk to ensure headers exist before libprism_mtl builds   │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Step-by-Step Process

### Step 0: Compile Temp Core Classes

**Purpose**: Provide javafx.base and javafx.graphics classes needed by shader compilers without waiting for main Java compilation.

**Process**:
1. Generate `VersionInfo.java` from template in javafx.base
2. Compile javafx.base to `temp-modules/javafx.base/`
3. Compile javafx.graphics to `temp-modules/javafx.graphics/` with module-path to temp javafx.base

**Key Points**:
- Compiles 311 classes from javafx.base
- Compiles 1,563 classes from javafx.graphics
- Uses `--module-path` and `--add-modules` for proper module compilation
- These are temporary classes used only during shader generation
- Final Java compilation creates the real module classes

**Marker**: `BUILD_BASE_CORE_TEMP`, `BUILD_GRAPHICS_CORE_TEMP` (SetupJavaCompilation outputs)

**Dependencies**: None (first step)

---

### Step 1: Generate ANTLR Parser

**Purpose**: Generate Java parser for JSL (Java Shader Language) grammar.

**Pre-condition**: `antlr-4.13.2-complete.jar` must already be present at `make/data/javafx-tools/` — it is copied there by the repository setup script, **not** downloaded during the build.

**Process**:
1. Run ANTLR on `JSL.g4` grammar file
2. Generate 6 Java files: Lexer, Parser, Listener, Visitor, and base classes

**Output Files**:
```
support/gensrc/javafx.graphics/antlr/
├── JSLLexer.java
├── JSLParser.java
├── JSLListener.java
├── JSLBaseListener.java
├── JSLVisitor.java
└── JSLBaseVisitor.java
```

**Marker**: `ANTLR_OUTPUT_MARKER` (`.../antlr/_antlr.marker`)

**Dependencies**: `antlr-4.13.2-complete.jar` (pre-placed)

---

### Step 2: Compile JSLC Compiler

**Purpose**: Compile the base JSL compiler that all shader compilers use.

**Process**:
- Compile `src/jslc/java/*.java` + generated ANTLR files
- Output to `classes/java/jslc/`

**Marker**: `BUILD_JSLC_COMPILER` (SetupJavaCompilation output)

**Dependencies**:
- `ANTLR_GENERATED_FILES` (Step 1)

**Classpath**:
- `antlr-4.13.2-complete.jar`

---

### Step 3: Compile Decora Shader Compilers

**Purpose**: Compile specialized compilers for Decora effect shaders.

**Process**:
- Compile `src/main/jsl-decora/*.java` (9 files including CompileBlend, CompilePhong, etc.)
- Output to `classes/jsl-compilers/decora/`

**Marker**: `BUILD_DECORA_COMPILERS` (SetupJavaCompilation output)

**Dependencies**:
- `BUILD_JSLC_COMPILER` (Step 2)
- `BUILD_GRAPHICS_CORE_TEMP` (Step 0) - needs Effect classes from javafx.graphics

**Classpath**:
- JSLC classes
- ANTLR jar
- Temp javafx.graphics classes
- Temp javafx.base classes

---

### Step 4: Generate Decora Shaders

**Purpose**: Generate Decora effect shaders in multiple formats from JSL source files.

**Process**:
- Run `GenAllDecoraShaders` which iterates through effect types (Blend, Phong, LinearConvolve, etc.)
- Each generates multiple backend implementations

**Command**:
```bash
java --module-path temp-modules/javafx.base:temp-modules/javafx.graphics \
     --add-modules=javafx.base,javafx.graphics \
     --add-exports=javafx.graphics/com.sun.scenario.effect=ALL-UNNAMED \
     -cp ANTLR:JSLC:Decora-compilers:DecoraSources \
     GenAllDecoraShaders -i jsl-decora/ -o jsl-decora-temp/ \
     -t -pkg com/sun/scenario/effect -all GenAllDecoraShaders
```

**Output**:
```
jsl-decora-temp/com/sun/scenario/effect/impl/
├── sw/java/*.java         (Software renderer - pure Java, all platforms)
├── sw/sse/*.java          (SSE optimized, all platforms)
├── prism/ps/*.java        (Prism shader pipeline, all platforms)
├── hw/d3d/hlsl/*.hlsl     (DirectX HLSL shaders, Windows only)
└── hw/mtl/msl/*.metal     (Metal Shading Language, macOS only)
```

**Marker**: `DECORA_SHADER_MARKER` (`.decora_shaders.marker`)

**Dependencies**:
- `BUILD_DECORA_COMPILERS` (Step 3)

**Module Exports**: Requires access to Effect, Light, and RenderState classes from temp javafx.graphics

---

### Step 5b: Compile Decora HLSL Shaders (Windows only)

**Purpose**: Compile generated Decora HLSL shaders to DirectX `.obj` bytecode files, ready to be copied alongside `.java` files in the flatten step.

**Process** (Windows only):
```bash
for FILE in jsl-decora-temp/com/sun/scenario/effect/impl/hw/d3d/hlsl/*.hlsl; do
  fxc /nologo /T ps_3_0 /Fo $DIR/$(basename $FILE .hlsl).obj $FILE
done
```

**Key Design Decision**: `.obj` files are written **into the same `jsl-decora-temp` tree** where the `.hlsl` files live. This mirrors exactly how Metal `.metallib` files are handled on macOS — the flatten step (Step 5) then copies everything, including `.obj` files, to the gensrc output in one go. No changes to the jfx source tree are needed.

**Marker**: `.decora_hlsl.marker`

**Dependencies**:
- `DECORA_SHADER_MARKER` (Step 4) — `.hlsl` files must exist before FXC runs

**Why Recipe-Level Loop** (not pattern rules):
At makefile parse time, the `.hlsl` source files don't exist yet (they're generated in Step 4). Using `$(wildcard ...)` at parse time would return empty, making the target a no-op. A shell `for` loop in the recipe evaluates the glob at runtime, after the `.hlsl` files are present.

---

### Step 5: Flatten Decora Shaders

**Purpose**: Copy generated shaders (`.java`, `.hlsl`, `.obj`, `.metal`) to final gensrc output, removing temp directory structure.

**Process**:
```bash
cp -R jsl-decora-temp/com → gensrc/javafx.graphics/com
```

**Reason**:
- Java.gmk will include `gensrc/javafx.graphics/` in source compilation
- We don't want `jsl-decora-temp/` directory in the final module
- Java.gmk explicitly excludes `jsl-*` patterns to avoid duplication
- `.obj` files in the temp tree are carried over automatically

**On Windows**: This step waits for both `DECORA_SHADER_MARKER` **and** `.decora_hlsl.marker`, ensuring `.obj` files are compiled before the copy happens.

**Marker**: `SHADER_FLATTEN_MARKER` (`.shaders_flattened`)

**Dependencies**:
- `DECORA_SHADER_MARKER` (Step 4)
- `.decora_hlsl.marker` (Step 5b) — **Windows only**

---

### Step 5a: Compile Decora Metal Shaders (macOS only)

**Purpose**: Compile Decora Metal shaders to native .air format.

**Process** (macOS only):
```bash
for FILE in jsl-decora-temp/com/sun/scenario/effect/impl/hw/mtl/msl/*.metal; do
  xcrun metal -Wdeprecated -std=macos-metal2.4 \
    -I mtl-headers -c $FILE -o msl/Decora/$(basename $FILE .metal).air
done
```

**Critical Side Effect**:
⚠️ **The Metal compiler creates `DecoraShaderCommon.h` header file!**

When compiling the first Decora Metal shader, the Metal compiler generates:
- `DecoraShaderCommon.h` (1,267 lines) - function declarations for all Decora shaders
- `FragmentShaderCommon.h` (1,329 lines) - common fragment shader utilities

**Output**:
- `msl/Decora/*.air` (93 files)
- `mtl-headers/DecoraShaderCommon.h` ✅
- `mtl-headers/FragmentShaderCommon.h` ✅

**Marker**: `DECORA_MSL_MARKER` (`_decora_msl.marker`)

**Dependencies**:
- `SHADER_FLATTEN_MARKER` (Step 5)

---

### Step 6: Compile Prism Shader Compilers

**Purpose**: Compile specialized compilers for Prism rendering pipeline shaders.

**Process**:
- Compile `src/main/jsl-prism/*.java` (CompileJSL and related)
- Output to `classes/jsl-compilers/prism/`

**Marker**: `BUILD_PRISM_COMPILERS` (SetupJavaCompilation output)

**Dependencies**:
- `BUILD_JSLC_COMPILER` (Step 2)
- `BUILD_GRAPHICS_CORE_TEMP` (Step 0)

**Classpath**: Same as Decora compilers

---

### Step 7: Generate Prism Shaders

**Purpose**: Generate Prism rendering pipeline shaders from JSL files.

**Process**:
⚠️ **CRITICAL: Uses sequential for loop to prevent header corruption!**

```bash
for FILE in src/main/jsl-prism/*.jsl; do
  java CompileJSL -i jsl-prism/ -o jsl-prism-temp/ \
    -t -pkg com/sun/prism [-d3d | -mtl -es2 | -es2] -name $FILE
done
```

**Why Sequential Execution is Critical**:
- Each `CompileJSL` invocation **APPENDS** to `PrismShaderCommon.h`
- Parallel execution would cause:
  - Race conditions with multiple processes writing simultaneously
  - Incomplete file (e.g., 4,660 lines instead of 9,982)
  - Corrupted content with misplaced `#endif` directives
  - Missing function declarations

**Pipeline options by OS**:

|---------|--------------|
| OS      | Options      |
|---------|--------------|
| Windows | `-d3d`       |
| macOS   | `-mtl -es2`  |
| Linux   | `-es2`       |
|---------|--------------|

**Output**:
```
jsl-prism-temp/com/sun/prism/
├── d3d/hlsl/*.hlsl      (DirectX shaders, Windows only)
├── es2/gl/*.glsl        (OpenGL shaders, macOS/Linux)
└── mtl/msl/*.metal      (Metal shaders, macOS only)
```

**Marker**: `PRISM_SHADER_MARKER` (`.prism_shaders.marker`)

**Dependencies**:
- `BUILD_PRISM_COMPILERS` (Step 6)

---

### Step 8b: Compile Prism HLSL Shaders (Windows only)

**Purpose**: Compile generated Prism HLSL shaders to DirectX `.obj` bytecode files.

**Process** (Windows only):
```bash
for FILE in jsl-prism-temp/com/sun/prism/d3d/hlsl/*.hlsl; do
  fxc /nologo /T ps_3_0 /Fo $DIR/$(basename $FILE .hlsl).obj $FILE
done
```

**Key Design Decision**: Same as Step 5b — `.obj` files go into **the same `jsl-prism-temp/` tree** so the flatten step copies them automatically.

**Marker**: `.prism_hlsl.marker`

**Dependencies**:
- `PRISM_SHADER_MARKER` (Step 7) — `.hlsl` files must exist before FXC runs

---

### Step 8: Flatten Prism Shaders

**Purpose**: Copy Prism shaders (and `.obj` files on Windows) to final gensrc output.

**Process**:
```bash
cp -R jsl-prism-temp/com → gensrc/javafx.graphics/com
```

**On Windows**: This step waits for both `PRISM_SHADER_MARKER` **and** `.prism_hlsl.marker`, ensuring `.obj` files are compiled before the copy.

**Marker**: `PRISM_FLATTEN_MARKER` (`.prism_flattened`)

**Dependencies**:
- `PRISM_SHADER_MARKER` (Step 7)
- `.prism_hlsl.marker` (Step 8b) — **Windows only**

---

### Step 8a: Compile Prism Metal Shaders (macOS only)

**Purpose**: Compile Prism Metal shaders to native .air format.

**Process** (macOS only):
```bash
for FILE in jsl-prism-temp/com/sun/prism/mtl/msl/*.metal; do
  xcrun metal -Wdeprecated -std=macos-metal2.4 \
    -I mtl-headers -c $FILE -o msl/Prism/$(basename $FILE .metal).air
done
```

**Critical Side Effect**:
⚠️ **The Metal compiler UPDATES `PrismShaderCommon.h` to its final complete size!**

The header grows from ~4,000 lines (after Step 7) to **9,982 lines** (complete) as Metal compiler processes all Prism shaders.

**Output**:
- `msl/Prism/*.air` (multiple files)
- `mtl-headers/PrismShaderCommon.h` **UPDATED to 9,982 lines** ✅

**Marker**: `PRISM_MSL_MARKER` (`_prism_msl.marker`)

**Dependencies**:
- `PRISM_FLATTEN_MARKER` (Step 8)

---

### Step 9: Compile Native Metal Shaders + Link Metal Library (macOS only)

**Purpose**: Compile pre-written Metal shaders from native source, then link everything into a single `.metallib`.

**Compilation**:
```bash
for FILE in src/main/native-prism-mtl/msl/*.metal; do
  xcrun metal -std=macos-metal2.4 -c $FILE → *.air
done
```

**Linking** (after Decora, Prism, and Native .air files are all ready):
```bash
xcrun metallib $(find msl/ -name "*.air") -o jfxshaders.metallib
```

Combines:
- Decora .air files (93 files)
- Prism .air files
- Native .air files

**Output**: `msl/com/sun/prism/mtl/msl/jfxshaders.metallib`

**Dependencies (linking)**:
- `DECORA_MSL_MARKER` (Step 5a)
- `PRISM_MSL_MARKER` (Step 8a)
- `NATIVE_MSL_MARKER` (native compilation above)

---

### Step 10: Copy metallib to Final Location (macOS only)

**Purpose**: Copy metallib to gensrc output for module inclusion.

**Process**:
```bash
cp msl/.../jfxshaders.metallib → gensrc/javafx.graphics/com/sun/prism/mtl/msl/
```

Java.gmk will include this metallib file in the final javafx.graphics module.

**Dependencies**:
- Metal library output (Step 9 link)

---

## Critical Dependencies

### Dependency Chain Diagram

```
VersionInfo.java
    │
    ▼
BUILD_BASE_CORE_TEMP (311 classes)
    │
    ▼
BUILD_GRAPHICS_CORE_TEMP (1,563 classes) ◄──────┐
    │                                           │
    ├──────────────────────────────────┐        │
    ▼                                  ▼        │
ANTLR_OUTPUT    ──►  BUILD_JSLC  ──►  BUILD_DECORA_COMPILERS
    │                    │                      │
    │                    │                      ▼
    │                    │              DECORA_SHADER_MARKER
    │                    │                      │
    │                    │        ┌─────────────┤ (Windows: also waits)
    │                    │        ▼             │
    │                    │  HLSL_DECORA_MARKER  │
    │                    │  (.decora_hlsl)      │
    │                    │        │             │
    │                    │        └──────┬──────┘
    │                    │               ▼
    │                    │       SHADER_FLATTEN_MARKER
    │                    │               │
    │                    │               ▼ (macOS only)
    │                    │       DECORA_MSL_MARKER ──────┐
    │                    │       (Creates DecoraShaderCommon.h)
    │                    │               │               │
    │                    ▼               │               │
    │            BUILD_PRISM_COMPILERS   │               │
    │                    │               │               │
    │                    ▼               │               │
    │            PRISM_SHADER_MARKER     │               │
    │            (Sequential for loop!)  │               │
    │                    │               │               │
    │        ┌───────────┤ (Windows)     │               │
    │        ▼           │               │               │
    │  HLSL_PRISM_MARKER │               │               │
    │  (.prism_hlsl)     │               │               │
    │        │           │               │               │
    │        └─────┬─────┘               │               │
    │              ▼                     │               │
    │      PRISM_FLATTEN_MARKER          │               │
    │              │                     │               │
    │              ▼ (macOS only)        │               │
    │      PRISM_MSL_MARKER              │               │
    │      (Updates PrismShaderCommon.h) │               │
    │              │                     │               │
    │              └──────────┐          │               │
    ▼                         ▼          │               │
NATIVE_MSL_MARKER       METAL_LIB_OUTPUT                 │
                                │                        │
                                ▼                        │
                        METALLIB_GENSRC_OUTPUT           │
                                                         │
                    ┌────────────────────────────────────┘
                    ▼
            MTL_HEADERS_READY_MARKER
            (All 3 headers complete! - macOS only)
```

---

## Execution Order Guarantees

### Makefile Dependency System

The build uses **marker files** to enforce execution order:

1. **Recipe-level Dependencies**: Each target lists its prerequisites
   ```makefile
   $(DECORA_SHADER_MARKER): $(BUILD_DECORA_COMPILERS)
   ```
   Make guarantees prerequisites complete before the recipe runs.

2. **Marker Files**: Each step creates a marker file (`.marker` or timestamp file)
   - Marker created only when step completes successfully
   - Subsequent steps depend on these markers
   - Enables incremental builds (step skipped if marker exists and inputs unchanged)

3. **Pre-declared Variables**: `HLSL_DECORA_MARKER` and `HLSL_PRISM_MARKER` are assigned **before** they are referenced in flatten prerequisites:
   ```makefile
   # Pre-declared before flatten steps
   HLSL_DECORA_MARKER :=
   HLSL_PRISM_MARKER :=
   ifeq ($(call isTargetOs, windows), true)
     HLSL_DECORA_MARKER := .../decora_hlsl.marker
     HLSL_PRISM_MARKER  := .../prism_hlsl.marker
   endif
   ```
   On non-Windows these are empty, so the flatten steps have no extra dependency.

4. **SetupJavaCompilation Output**: The `$(BUILD_*)` variables contain marker files
   - Example: `BUILD_BASE_CORE_TEMP` expands to the batch marker file path
   - Used as dependencies: `DEPENDS := $(BUILD_GRAPHICS_CORE_TEMP)`

### Sequential Execution for Prism Shaders

**Problem**: Make pattern rules execute in parallel by default:
```makefile
# This runs in parallel (causes corruption):
target_%.marker: source_%.jsl
  process $<
```

**Solution**: Use single target with for loop:
```makefile
# This runs sequentially:
target.marker: $(ALL_JSL_FILES)
  @for FILE in $(ALL_JSL_FILES); do
    process $$FILE;
  done
```

### Recipe-Level Loops for HLSL (and Metal)

**Problem**: `$(wildcard ...)` expands at **parse time**, before any shaders are generated:
```makefile
# ❌ HLSL files don't exist yet at parse time - objects list will be empty:
HLSL_OBJECTS := $(patsubst %.hlsl, %.obj, $(wildcard $(HLSL_DIR)/*.hlsl))
```

**Solution**: Use a shell `for` loop in the recipe, which evaluates the glob at runtime:
```makefile
# ✅ Glob evaluated at runtime, after .hlsl files exist:
$(HLSL_MARKER): $(SHADER_MARKER)
  for FILE in $(HLSL_DIR)/*.hlsl; do
    fxc ... $$FILE;
  done
```

This is the same pattern used for Metal shader compilation on macOS.

### Phase Ordering

The OpenJDK build system executes phases in order **for each module**:
```
gensrc → java → libs → launchers → jmods
```

For javafx.graphics:
1. `javafx.graphics-gensrc` runs first, creating all shaders and headers
2. `javafx.graphics-java` compiles the module, including generated shader sources
3. `javafx.graphics-libs` builds native libraries (libprism_mtl) using generated headers

**Guarantee**: `javafx.graphics-libs` always runs after `javafx.graphics-gensrc` completes.

---

## Common Issues and Solutions

### Issue 1: PrismShaderCommon.h Corruption

**Symptoms**:
- Header has 4,660 lines instead of 9,982
- Line 2668 has misplaced `#endif`
- Missing function declarations
- Compilation errors: "call to undeclared function"

**Root Cause**:
Parallel execution of Prism shader generation causes multiple processes to write to the same header file simultaneously.

**Working Solution**:
✅ Replace pattern rule with single target using sequential for loop (see Step 7)

---

### Issue 2: DecoraShaderCommon.h Not Generated

**Symptoms**:
- Only `PrismShaderCommon.h` and `FragmentShaderCommon.h` exist
- `DecoraShaderCommon.h` missing
- Compilation error: `'DecoraShaderCommon.h' file not found`
- Metal library (libprism_mtl) fails to compile

**Root Cause**:
`DecoraShaderCommon.h` is created as a **side effect** of compiling Decora Metal shaders (Step 5a). If the Decora MSL compilation step doesn't run, this header is never created.

**Solution**:
✅ Make `MTL_HEADERS_READY_MARKER` depend on `DECORA_MSL_MARKER`:
```makefile
$(MTL_HEADERS_READY_MARKER): $(SHADER_FLATTEN_MARKER) $(PRISM_FLATTEN_MARKER) $(DECORA_MSL_MARKER)
```

---

### Issue 3: HLSL .obj Files Not Found at Runtime (Windows)

**Symptoms**:
- Build succeeds but `getResourceAsStream("hlsl/Name.obj")` returns null
- D3D renderer fails to load shaders at runtime

**Root Cause**:
Previously, `.obj` files were written to a separate output directory or to the jfx source tree, neither of which is picked up as module resources by the Java compiler.

**Working Solution**:
✅ Write `.obj` files into the **same temp directory** as the `.hlsl` source files (`jsl-decora-temp/` and `jsl-prism-temp/`). The flatten step then copies them to `gensrc/javafx.graphics/com/sun/...`, where they become module resources compiled into `javafx.graphics`.

---

### Issue 4: HLSL Objects Not Compiled (Empty for Loop)

**Symptoms**:
- `.decora_hlsl.marker` or `.prism_hlsl.marker` created but empty
- No `.obj` files in temp dirs

**Root Cause**:
Pattern rules using `$(wildcard ...)` at parse time find no `.hlsl` files because they haven't been generated yet.

**Working Solution**:
✅ Use a recipe-level shell `for` loop with a glob pattern. The glob runs at recipe execution time, after the `.hlsl` files have been generated by the preceding step.

---

### Issue 5: Flatten Step Runs Before HLSL Compilation (Windows)

**Symptoms**:
- `.obj` files missing from gensrc output
- `cp -R` in flatten step runs before FXC has produced `.obj` files

**Root Cause**:
`HLSL_DECORA_MARKER` / `HLSL_PRISM_MARKER` were either not defined yet when referenced in flatten prerequisites, or were not listed as dependencies.

**Working Solution**:
✅ Pre-declare both HLSL marker variables before the flatten step, then assign them inside the `ifeq ($(call isTargetOs, windows), true)` block. The flatten step prerequisites reference these variables, which are empty on non-Windows (no extra dependency) and point to the HLSL marker files on Windows.

---

### Issue 6: Missing hw/ Directories in Decora Output

```bash
ls build/jfx/support/javafx-build/javafx.graphics/jsl-decora-temp/com/sun/scenario/effect/impl/
# Should show: hw/, sw/, prism/
```

**Cause**: Java version mismatch or missing module exports. **Fix**: Verify `--add-exports` flags.

---

### Issue 7: libprism_mtl Compilation Fails (macOS)

**Symptoms**:
- `MetalShader.m` compilation fails
- Error: `'DecoraShaderCommon.h' file not found`
- libprism_mtl not built

**Working Solution**:
✅ Trust OpenJDK phase ordering — gensrc always completes before libs for the same module. Ensure `MTL_HEADERS_READY_MARKER` depends on all header-generating steps (including `DECORA_MSL_MARKER`).

---

## Directory Structure

### Input Directories
```
OPENJFX_MODULES_SRC/modules/javafx.graphics/
├── src/main/java/                    # Core Java sources
├── src/main/version-info/            # VersionInfo.java template
├── src/jslc/java/                    # JSLC compiler sources
├── src/jslc/antlr/JSL.g4             # JSL grammar
├── src/jslc/resources/               # Compiler resources
├── src/main/jsl-decora/              # Decora JSL sources + compilers
│   ├── *.jsl                         # Shader definitions
│   └── Compile*.java                 # Shader compilers
├── src/main/jsl-prism/               # Prism JSL sources + compiler
│   ├── *.jsl                         # Shader definitions
│   └── CompileJSL.java               # Shader compiler
└── src/main/native-prism-mtl/        # Metal library native source
    ├── *.m, *.h                      # Objective-C source
    └── msl/*.metal                   # Native Metal shaders
```

### Build Data
```
make/data/javafx-tools/
└── antlr-4.13.2-complete.jar         # Pre-placed by setup script (not downloaded)
```

### Output Directories
```
build/jfx/support/javafx-build/javafx.graphics/
├── temp-modules/                     # Temp core classes (Step 0)
│   ├── javafx.base/                  # 311 classes
│   └── javafx.graphics/              # 1,563 classes
├── classes/                          # Compiled shader compilers
│   ├── java/jslc/                    # JSLC compiler classes
│   └── jsl-compilers/
│       ├── decora/                   # Decora compiler classes
│       └── prism/                    # Prism compiler classes
├── jsl-decora-temp/                  # Generated Decora shaders (temp)
│   └── com/sun/scenario/effect/impl/
│       ├── sw/java/*.java
│       ├── sw/sse/*.java
│       ├── prism/ps/*.java
│       ├── hw/d3d/hlsl/*.hlsl        # (also *.obj on Windows, compiled in place)
│       └── hw/mtl/msl/*.metal
├── jsl-prism-temp/                   # Generated Prism shaders (temp)
│   └── com/sun/prism/
│       ├── d3d/hlsl/*.hlsl           # (also *.obj on Windows, compiled in place)
│       ├── es2/gl/*.glsl       
