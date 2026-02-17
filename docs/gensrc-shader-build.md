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
5. **Native Compilation**: Compile Metal shaders to native .air and .metallib formats
6. **Flattening**: Copy generated sources to final gensrc output directory

### Key Challenge

The shader compilers need classes from javafx.graphics to compile, but javafx.graphics itself needs the generated shaders to compile. This circular dependency is resolved by compiling core classes to a **temporary location** first.

### Cross-Platform Support

The build system supports **Windows, macOS, and Linux**:

- **Path Separators**: Automatically configured based on target OS
  - Unix/Linux/macOS: `:` (colon)
  - Windows: `;` (semicolon)
- **Platform-Specific Shaders**: 
  - Metal shaders (`.metal`) compiled only on macOS/iOS
  - DirectX shaders (`.hlsl`) compiled only on Windows
  - OpenGL shaders (`.glsl`, `.frag`) compiled on all platforms

---

## Build Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                    JAVAFX GRAPHICS GENSRC PHASE                      │
└─────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│ STEP 0: Compile Temp Core Classes                                    │
├──────────────────────────────────────────────────────────────────────┤
│ VersionInfo.java                                                     │
│       │                                                               │
│       ▼                                                               │
│ BUILD_BASE_CORE_TEMP ────────────► temp-modules/javafx.base/        │
│  (311 classes)                      - javafx.beans.*                 │
│                                     - javafx.collections.*           │
│       │                             - com.sun.javafx.*               │
│       ▼                                                               │
│ BUILD_GRAPHICS_CORE_TEMP ──────► temp-modules/javafx.graphics/      │
│  (1,563 classes)                    - com.sun.scenario.effect.*     │
│                                     - com.sun.javafx.*               │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 1: Download ANTLR Parser Generator                              │
├──────────────────────────────────────────────────────────────────────┤
│ Download antlr-4.13.2-complete.jar                                   │
│       │                                                               │
│       ▼                                                               │
│ Generate parser from JSL.g4 grammar ──► antlr/*.java                │
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
│  Input: src/jslc/java/*.java + antlr/*.java                         │
│  Output: classes/java/jslc/*.class                                   │
│  Classpath: antlr-4.13.2-complete.jar                               │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 3: Compile Decora Shader Compilers                              │
├──────────────────────────────────────────────────────────────────────┤
│ BUILD_DECORA_COMPILERS                                               │
│  Input: src/main/jsl-decora/*.java                                   │
│  Output: classes/jsl-compilers/decora/*.class                        │
│  Classpath: JSLC + ANTLR + temp javafx.graphics (for Effect classes)│
│  Dependencies: BUILD_JSLC_COMPILER, BUILD_GRAPHICS_CORE_TEMP         │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 4: Generate Decora Shaders                                      │
├──────────────────────────────────────────────────────────────────────┤
│ GenAllDecoraShaders (runs CompileBlend, CompilePhong, etc.)         │
│  Input: src/main/jsl-decora/*.jsl                                    │
│  Output: jsl-decora-temp/com/sun/scenario/effect/impl/              │
│    ├─ sw/java/*.java          (Software renderer)                   │
│    ├─ sw/sse/*.java            (SSE optimized)                       │
│    ├─ prism/ps/*.java          (Prism pipeline)                      │
│    ├─ hw/d3d/hlsl/*.hlsl       (DirectX shaders)                     │
│    └─ hw/mtl/msl/*.metal       (Metal shaders)                       │
│                                                                       │
│ Marker: .decora_shaders.marker                                       │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 5: Flatten Decora Shader Structure                              │
├──────────────────────────────────────────────────────────────────────┤
│ Copy from jsl-decora-temp/ to gensrc/javafx.graphics/               │
│  - Preserves com/sun/scenario/effect package structure              │
│  - Avoids jsl-decora-temp in final module output                    │
│                                                                       │
│ Marker: .shaders_flattened                                           │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 6: Compile Decora Metal Shaders (macOS/iOS only)               │
├──────────────────────────────────────────────────────────────────────┤
│ Compile each .metal file sequentially:                              │
│   xcrun metal -I mtl-headers *.metal → *.air                        │
│                                                                       │
│ ⚠️  CRITICAL: This step creates DecoraShaderCommon.h (1,267 lines)  │
│     as a side effect when compiling the first Decora Metal shader!  │
│                                                                       │
│ Output: msl/Decora/*.air (93 files)                                 │
│ Output: mtl-headers/DecoraShaderCommon.h (1,267 lines)              │
│ Output: mtl-headers/FragmentShaderCommon.h (1,329 lines)            │
│                                                                       │
│ Marker: _decora_msl.marker                                           │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 7: Compile Prism Shader Compilers                               │
├──────────────────────────────────────────────────────────────────────┤
│ BUILD_PRISM_COMPILERS                                                │
│  Input: src/main/jsl-prism/*.java                                    │
│  Output: classes/jsl-compilers/prism/*.class                         │
│  Classpath: JSLC + ANTLR + temp javafx.graphics                     │
│  Dependencies: BUILD_JSLC_COMPILER, BUILD_GRAPHICS_CORE_TEMP         │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 8: Generate Prism Shaders                                       │
├──────────────────────────────────────────────────────────────────────┤
│ ⚠️  CRITICAL: Sequential for loop prevents header corruption!        │
│                                                                       │
│ For each .jsl file (SEQUENTIALLY):                                   │
│   CompileJSL *.jsl → multiple shader variants                        │
│                                                                       │
│ Output: jsl-prism-temp/com/sun/prism/                               │
│   ├─ d3d/*.hlsl              (DirectX shaders)                       │
│   ├─ es2/gl/*.glsl           (OpenGL ES 2.0 shaders)                 │
│   └─ mtl/msl/*.metal         (Metal shaders)                         │
│                                                                       │
│ ⚠️  Each CompileJSL invocation APPENDS to PrismShaderCommon.h       │
│     Must run sequentially to avoid corruption!                       │
│                                                                       │
│ Marker: .prism_shaders.marker                                        │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 9: Flatten Prism Shader Structure                               │
├──────────────────────────────────────────────────────────────────────┤
│ Copy from jsl-prism-temp/ to gensrc/javafx.graphics/                │
│  - Preserves com/sun/prism package structure                        │
│  - Avoids jsl-prism-temp in final module output                     │
│                                                                       │
│ Marker: .prism_flattened                                             │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 10: Compile Prism Metal Shaders (macOS/iOS only)               │
├──────────────────────────────────────────────────────────────────────┤
│ Compile each .metal file sequentially:                              │
│   xcrun metal -I mtl-headers *.metal → *.air                        │
│                                                                       │
│ ⚠️  CRITICAL: This step UPDATES PrismShaderCommon.h to full size!   │
│     Final size: 9,982 lines                                          │
│                                                                       │
│ Output: msl/Prism/*.air (multiple files)                            │
│ Output: mtl-headers/PrismShaderCommon.h (9,982 lines - COMPLETE!)   │
│                                                                       │
│ Marker: _prism_msl.marker                                            │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 11: Compile Native Metal Shaders                                │
├──────────────────────────────────────────────────────────────────────┤
│ Compile built-in Metal shaders from native-prism-mtl/msl/           │
│   xcrun metal *.metal → *.air                                        │
│                                                                       │
│ Marker: _native_msl.marker                                           │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 12: Link Metal Library                                          │
├──────────────────────────────────────────────────────────────────────┤
│ Link all .air files into single metallib:                           │
│   xcrun metallib *.air → jfxshaders.metallib                        │
│                                                                       │
│ Output: msl/com/sun/prism/mtl/msl/jfxshaders.metallib              │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ STEP 13: Copy metallib to Final Location                            │
├──────────────────────────────────────────────────────────────────────┤
│ Copy to gensrc output for inclusion in module                       │
│ Output: gensrc/javafx.graphics/com/sun/prism/mtl/msl/*.metallib    │
└──────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ FINAL MARKER: .headers_ready                                         │
├──────────────────────────────────────────────────────────────────────┤
│ Created after all shader generation and Metal compilation complete  │
│ Used by Lib.gmk to ensure headers exist before libprism_mtl builds  │
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

### Step 1: Download ANTLR and Generate Parser

**Purpose**: Generate Java parser for JSL (Java Shader Language) grammar.

**Process**:
1. Download `antlr-4.13.2-complete.jar` if not present
2. Run ANTLR on `JSL.g4` grammar file
3. Generate 6 Java files: Lexer, Parser, Listener, Visitor, and base classes

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

**Dependencies**: None

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
├── sw/java/*.java         (Software renderer - pure Java)
├── sw/sse/*.java          (SSE optimized)
├── prism/ps/*.java        (Prism shader pipeline)
├── hw/d3d/hlsl/*.hlsl     (DirectX HLSL shaders)
└── hw/mtl/msl/*.metal     (Metal Shading Language)
```

**Marker**: `DECORA_SHADER_MARKER` (`.decora_shaders.marker`)

**Dependencies**:
- `BUILD_DECORA_COMPILERS` (Step 3)

**Module Exports**: Requires access to Effect, Light, and RenderState classes from temp javafx.graphics

---

### Step 5: Flatten Decora Shaders

**Purpose**: Copy generated shaders to final gensrc output, removing temp directory structure.

**Process**:
```bash
cp -R jsl-decora-temp/com → gensrc/javafx.graphics/com
```

**Reason**: 
- Java.gmk will include `gensrc/javafx.graphics/` in source compilation
- We don't want `jsl-decora-temp/` directory in the final module
- Java.gmk explicitly excludes `jsl-*` patterns to avoid duplication

**Marker**: `SHADER_FLATTEN_MARKER` (`.shaders_flattened`)

**Dependencies**:
- `DECORA_SHADER_MARKER` (Step 4)

---

### Step 6: Compile Decora Metal Shaders

**Purpose**: Compile Decora Metal shaders to native .air format.

**Process** (macOS/iOS only):
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

### Step 7: Compile Prism Shader Compilers

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

### Step 8: Generate Prism Shaders

**Purpose**: Generate Prism rendering pipeline shaders from JSL files.

**Process**:
⚠️ **CRITICAL: Uses sequential for loop to prevent header corruption!**

```bash
for FILE in src/main/jsl-prism/*.jsl; do
  java CompileJSL -i jsl-prism/ -o jsl-prism-temp/ \
    -t -pkg com/sun/prism -d3d -es2 -mtl -name $FILE
done
```

**Why Sequential Execution is Critical**:
- Each `CompileJSL` invocation **APPENDS** to `PrismShaderCommon.h`
- Parallel execution would cause:
  - Race conditions with multiple processes writing simultaneously
  - Incomplete file (e.g., 4,660 lines instead of 9,982)
  - Corrupted content with misplaced `#endif` directives
  - Missing function declarations

**Original Failed Approach**:
```makefile
# ❌ This caused corruption:
$(SUPPORT_OUTPUTDIR)/.prism_%.marker: %.jsl
  CompileJSL -name $<

.NOTPARALLEL: $(PRISM_SHADER_MARKERS)  # Doesn't actually serialize pattern rules!
```

**Working Approach**:
```makefile
# ✅ This prevents corruption:
$(PRISM_SHADER_MARKER): $(BUILD_PRISM_COMPILERS)
  @for FILE in $(PRISM_JSL_FILES); do
    CompileJSL -name $$FILE;
  done
```

**Output**:
```
jsl-prism-temp/com/sun/prism/
├── d3d/*.hlsl           (DirectX shaders)
├── es2/gl/*.glsl        (OpenGL shaders)
└── mtl/msl/*.metal      (Metal shaders)
```

**Marker**: `PRISM_SHADER_MARKER` (`.prism_shaders.marker`)

**Dependencies**:
- `BUILD_PRISM_COMPILERS` (Step 7)

---

### Step 9: Flatten Prism Shaders

**Purpose**: Copy Prism shaders to final gensrc output.

**Process**:
```bash
cp -R jsl-prism-temp/com → gensrc/javafx.graphics/com
```

**Marker**: `PRISM_FLATTEN_MARKER` (`.prism_flattened`)

**Dependencies**:
- `PRISM_SHADER_MARKER` (Step 8)

---

### Step 10: Compile Prism Metal Shaders

**Purpose**: Compile Prism Metal shaders to native .air format.

**Process** (macOS/iOS only):
```bash
for FILE in jsl-prism-temp/com/sun/prism/mtl/msl/*.metal; do
  xcrun metal -Wdeprecated -std=macos-metal2.4 \
    -I mtl-headers -c $FILE -o msl/Prism/$(basename $FILE .metal).air
done
```

**Critical Side Effect**:
⚠️ **The Metal compiler UPDATES `PrismShaderCommon.h` to its final complete size!**

The header grows from ~4,000 lines (after Step 8) to **9,982 lines** (complete) as Metal compiler processes all Prism shaders and adds platform-specific declarations.

**Output**:
- `msl/Prism/*.air` (multiple files)
- `mtl-headers/PrismShaderCommon.h` **UPDATED to 9,982 lines** ✅

**Marker**: `PRISM_MSL_MARKER` (`_prism_msl.marker`)

**Dependencies**:
- `PRISM_FLATTEN_MARKER` (Step 9)

---

### Step 11: Compile Native Metal Shaders

**Purpose**: Compile pre-written Metal shaders from native source.

**Process**:
```bash
for FILE in src/main/native-prism-mtl/msl/*.metal; do
  xcrun metal -std=macos-metal2.4 -c $FILE → *.air
done
```

**Marker**: `NATIVE_MSL_MARKER` (`_native_msl.marker`)

**Dependencies**: None (independent of generated shaders)

---

### Step 12: Link Metal Library

**Purpose**: Combine all Metal .air files into single metallib bundle.

**Process**:
```bash
xcrun metallib msl/**/*.air -o jfxshaders.metallib
```

Combines:
- Decora .air files (93 files)
- Prism .air files
- Native .air files

**Output**: `msl/com/sun/prism/mtl/msl/jfxshaders.metallib`

**Dependencies**:
- `DECORA_MSL_MARKER` (Step 6)
- `PRISM_MSL_MARKER` (Step 10)
- `NATIVE_MSL_MARKER` (Step 11)

---

### Step 13: Copy metallib to Final Location

**Purpose**: Copy metallib to gensrc output for module inclusion.

**Process**:
```bash
cp msl/.../jfxshaders.metallib → gensrc/javafx.graphics/com/sun/prism/mtl/msl/
```

Java.gmk will include this metallib file in the final javafx.graphics module.

**Dependencies**:
- Metal library output (Step 12)

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
    │                                            │
    ├──────────────────────────────────┐        │
    ▼                                  ▼        │
ANTLR_OUTPUT    ──►  BUILD_JSLC  ──►  BUILD_DECORA_COMPILERS
    │                    │                      │
    │                    │                      ▼
    │                    │              DECORA_SHADER_MARKER
    │                    │                      │
    │                    │                      ▼
    │                    │              SHADER_FLATTEN_MARKER
    │                    │                      │
    │                    │                      ▼
    │                    │              DECORA_MSL_MARKER ──────┐
    │                    │              (Creates DecoraShaderCommon.h)
    │                    │                      │               │
    │                    ▼                      │               │
    │            BUILD_PRISM_COMPILERS          │               │
    │                    │                      │               │
    │                    ▼                      │               │
    │            PRISM_SHADER_MARKER ◄──────────┘               │
    │            (Sequential for loop!)                         │
    │                    │                                      │
    │                    ▼                                      │
    │            PRISM_FLATTEN_MARKER                           │
    │                    │                                      │
    │                    ▼                                      │
    │            PRISM_MSL_MARKER                               │
    │            (Updates PrismShaderCommon.h to 9,982 lines)   │
    │                    │                                      │
    │                    └──────────────────┐                   │
    ▼                                       ▼                   │
NATIVE_MSL_MARKER                   METAL_LIB_OUTPUT           │
                                            │                   │
                                            ▼                   │
                                    METALLIB_GENSRC_OUTPUT      │
                                                                │
                    ┌───────────────────────────────────────────┘
                    ▼
            MTL_HEADERS_READY_MARKER
            (All 3 headers complete!)
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

3. **SetupJavaCompilation Output**: The `$(BUILD_*)` variables contain marker files
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

The `for` loop in the shell recipe ensures sequential execution within a single Make target.

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
Parallel execution of Prism shader generation causes multiple processes to write to the same header file simultaneously, resulting in corruption.

**Failed Solutions**:
- ❌ `.NOTPARALLEL: $(PRISM_SHADER_MARKERS)` - Doesn't serialize pattern rules
- ❌ Dependency chains between markers - Complex and unreliable

**Working Solution**:
✅ Replace pattern rule with single target using sequential for loop (see Step 8)

---

### Issue 2: DecoraShaderCommon.h Not Generated

**Symptoms**:
- Only PrismShaderCommon.h and FragmentShaderCommon.h exist
- DecoraShaderCommon.h missing
- Compilation error: `'DecoraShaderCommon.h' file not found`
- Metal library (libprism_mtl) fails to compile

**Root Cause**:
`DecoraShaderCommon.h` is created as a **side effect** of compiling Decora Metal shaders (Step 6). If the Decora MSL compilation step doesn't run, this header is never created.

**Cause of Step Being Skipped**:
- `DECORA_MSL_MARKER` not included in final TARGETS or marker dependencies
- Step 6 runs but isn't required by anything else

**Solution**:
✅ Make `MTL_HEADERS_READY_MARKER` depend on `DECORA_MSL_MARKER`:
```makefile
$(MTL_HEADERS_READY_MARKER): $(SHADER_FLATTEN_MARKER) $(PRISM_FLATTEN_MARKER) $(DECORA_MSL_MARKER)
```

---

### Issue 3: Temp Core Classes Version Mismatch

**Symptoms**:
- Error: "Unsupported major.minor version 71.0"
- GenAllDecoraShaders fails with ClassNotFoundException
- No hw/ directories in generated Decora shaders

**Root Cause**:
Temp core classes compiled with Java 27 bytecode, but shader generation tools expecting Java 25.

**Solution**:
✅ Use consistent Java version throughout (Java 27 everywhere, or --release 25 everywhere)

---

### Issue 4: Missing hw/ Directories in Decora Output

**Symptoms**:
- Only `sw/` and `prism/` directories generated
- No `hw/d3d/` or `hw/mtl/` directories
- Only software shaders generated, no hardware shaders

**Root Cause**:
Shader generation tool couldn't load Effect classes from temp modules due to version mismatch or missing module exports.

**Solution**:
✅ Ensure:
- Temp modules use correct Java version
- `--add-modules=javafx.base,javafx.graphics`
- `--add-exports` for all required internal packages
- Module-path correctly points to temp-modules

---

### Issue 5: Headers Not Available for libprism_mtl

**Symptoms**:
- `MetalShader.m` compilation fails
- Error: `'DecoraShaderCommon.h' file not found`
- libprism_mtl not built

**Root Cause**:
Lib.gmk tries to compile Metal library before gensrc has created the headers.

**Failed Solutions**:
- ❌ Wildcard checks: Evaluated at parse time before gensrc runs
- ❌ Dummy headers: Prevent real headers from being created
- ❌ DEPENDS in SetupJdkLibrary: Doesn't work across build phases

**Working Solution**:
✅ Trust OpenJDK phase ordering - gensrc always completes before libs for the same module. Simply remove conditional checks and declare the library target.

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
├── jsl-prism-temp/                   # Generated Prism shaders (temp)
│   └── com/sun/prism/
├── msl/                              # Compiled Metal shaders
│   ├── Decora/*.air                  # 93 files
│   ├── Prism/*.air                   # Multiple files
│   └── com/sun/prism/mtl/msl/
│       └── jfxshaders.metallib       # Final Metal library
└── mtl-headers/                      # Generated C/ObjC headers
    ├── DecoraShaderCommon.h          # 1,267 lines
    ├── FragmentShaderCommon.h        # 1,329 lines
    ├── PrismShaderCommon.h           # 9,982 lines
    └── .headers_ready                # Marker for Lib.gmk

build/jfx/support/gensrc/javafx.graphics/  # Final gensrc output
├── antlr/                            # Generated parser (Step 1)
└── com/                              # Flattened shader sources
    ├── sun/scenario/effect/          # Decora shaders (602 .java)
    └── sun/prism/                    # Prism shaders + metallib
```

---

## Marker Files Reference

### Purpose of Markers

Marker files are empty timestamp files created when a build step completes successfully. They serve two purposes:

1. **Dependency Tracking**: Subsequent steps depend on markers to ensure ordering
2. **Incremental Builds**: If marker exists and inputs haven't changed, step is skipped

### Marker File List

| Marker File | Step | Created By | Used By |
|-------------|------|------------|---------|
| `_antlr.marker` | 1 | ANTLR parser generation | BUILD_JSLC_COMPILER |
| `_the.BUILD_JSLC_COMPILER_batch` | 2 | JSLC compilation | Decora/Prism compilers |
| `_the.BUILD_DECORA_COMPILERS_batch` | 3 | Decora compiler compilation | Decora shader generation |
| `.decora_shaders.marker` | 4 | GenAllDecoraShaders | Shader flatten |
| `.shaders_flattened` | 5 | Decora flatten | Decora MSL compilation |
| `_decora_msl.marker` | 6 | Decora Metal compilation | MTL_HEADERS_READY |
| `_the.BUILD_PRISM_COMPILERS_batch` | 7 | Prism compiler compilation | Prism shader generation |
| `.prism_shaders.marker` | 8 | Prism shader generation (for loop) | Prism flatten |
| `.prism_flattened` | 9 | Prism flatten | Prism MSL compilation |
| `_prism_msl.marker` | 10 | Prism Metal compilation | Metal library linking |
| `_native_msl.marker` | 11 | Native Metal compilation | Metal library linking |
| `.headers_ready` | Final | After all headers created | Lib.gmk libprism_mtl |

---

## Generated Header Files

### DecoraShaderCommon.h (1,267 lines)

**Created By**: Decora Metal shader compilation (Step 6) as a side effect

**Contents**:
- Function declarations for all Decora effect shaders
- Example: `NSDictionary* getDECORADict(NSString *shaderName)`
- Argument buffer ID enums for Metal shaders
- Used by MetalShader.m in libprism_mtl

**When Created**: 
When the Metal compiler processes the first `.metal` file from Decora shaders, it generates this header containing declarations for all Decora shader entry points.

---

### FragmentShaderCommon.h (1,329 lines)

**Created By**: Decora Metal shader compilation (Step 6) as a side effect

**Contents**:
- Common fragment shader utilities
- Shared functions used across multiple shaders

---

### PrismShaderCommon.h (9,982 lines)

**Created By**: 
- Initially created/appended during Prism shader generation (Step 8)
- **UPDATED/COMPLETED** during Prism Metal shader compilation (Step 10)

**Contents**:
- Function declarations for all Prism rendering shaders
- Argument buffer ID enums
- Uniform structure definitions
- Platform-specific (Metal) declarations added during Metal compilation

**Critical Notes**:
- ⚠️ **Must be generated sequentially** (for loop in Step 8) to prevent corruption
- Grows incrementally as each Prism shader is processed
- Final size achieved after Metal shader compilation
- If generated in parallel, file will be incomplete/corrupted

**Expected Line Counts**:
- After Step 8 (shader generation): ~4,000-5,000 lines
- After Step 10 (Metal compilation): **9,982 lines** (complete)

---

## Build System Integration

### OpenJDK Build Phase Architecture

```
Module Build Phases (executed in order):
1. gensrc    → Generate source files (shaders, parsers, etc.)
2. java      → Compile Java sources (including generated)
3. libs      → Build native libraries
4. launchers → Build executable launchers
5. jmods     → Package into jmod files
```

**For javafx.graphics**:
```
javafx.graphics-gensrc
  ↓
javafx.graphics-java
  ↓
javafx.graphics-libs
```

### Integration Points

**Gensrc.gmk → Java.gmk**:
- Java.gmk includes `gensrc/javafx.graphics/` in SRC compilation
- Generated shader .java files are compiled into the module
- Java.gmk excludes `jsl-*` directory patterns to avoid temp artifacts
- **Note**: `.metal` and `.hlsl` files are NOT included in the final module (only used during native compilation)

**Gensrc.gmk → Lib.gmk**:
- Lib.gmk uses headers from `mtl-headers/` directory
- `MTL_HEADERS_READY_MARKER` indicates all headers are complete
- libprism_mtl compilation includes headers with `-I` flag

**Java.gmk → Module Output**:
- Generated shader .java source files are compiled into classes
- Shader resource files (.frag, .metallib) are copied into final module
- **Metal (.metal) and HLSL (.hlsl) files are excluded** - they're only intermediate files used during native shader compilation

---

## Performance Considerations

### Parallel Compilation

**What Runs in Parallel** (Safe):
- Different source files within SetupJavaCompilation
- Different modules (javafx.base and javafx.graphics temp compilation can overlap)
- Independent shader compiler compilation (Decora and Prism compilers)

**What Must Run Sequentially** (Required):
- ⚠️ **Prism shader generation** (Step 8) - Each JSL file must be processed one at a time
- Metal shader compilation within each step (for loops are sequential)

### Build Time

Typical build times on modern hardware:
- Step 0 (Temp class compilation): 20-30 seconds
- Steps 1-3 (ANTLR + compilers): 10-15 seconds
- Step 4 (Decora generation): 5-10 seconds
- Step 8 (Prism generation): 30-60 seconds (sequential)
- Steps 6, 10 (Metal compilation): 15-30 seconds
- **Total gensrc phase**: ~2-3 minutes

**Sequential Prism shader generation adds time but prevents corruption!**

---

## Troubleshooting Guide

### Header Corruption (4,660 lines instead of 9,982)

**Diagnosis**:
```bash
wc -l build/jfx/support/javafx-build/javafx.graphics/mtl-headers/PrismShaderCommon.h
# Expected: 9982
# Problem: 4660 or other incomplete number
```

**Cause**: Parallel Prism shader generation

**Fix**: Verify Step 8 uses for loop, not pattern rule

---

### Missing DecoraShaderCommon.h

**Diagnosis**:
```bash
ls build/jfx/support/javafx-build/javafx.graphics/mtl-headers/
# Should show: DecoraShaderCommon.h, FragmentShaderCommon.h, PrismShaderCommon.h
```

**Cause**: Decora Metal compilation (Step 6) didn't run

**Fix**: Ensure `MTL_HEADERS_READY_MARKER` depends on `DECORA_MSL_MARKER`

---

### No hw/ Directories in Decora Output

**Diagnosis**:
```bash
ls build/jfx/support/javafx-build/javafx.graphics/jsl-decora-temp/com/sun/scenario/effect/impl/
# Should show: hw/, sw/, prism/
# Problem: Only sw/ and prism/
```

**Cause**: 
- Java version mismatch preventing temp module loading
- Missing module exports preventing Effect class access

**Fix**: 
- Use consistent Java version
- Verify `--add-exports` flags include all required packages

---

### libprism_mtl Compilation Fails

**Diagnosis**:
```bash
make CONF=jfx javafx.graphics-libs
# Error: 'DecoraShaderCommon.h' file not found
```

**Cause**: Headers not generated yet or Lib.gmk wildcard check failed at parse time

**Fix**: 
- Remove conditional checks from Lib.gmk
- Trust OpenJDK phase ordering
- Ensure MTL_HEADERS_READY_MARKER depends on all header-generating steps

---

## Key Takeaways

1. ✅ **Temp core class compilation** solves the circular dependency between shader compilers and javafx.graphics
2. ✅ **Sequential for loop** for Prism shader generation prevents header corruption
3. ✅ **Marker files** enforce proper execution order through Make's dependency system
4. ✅ **Side effect headers** (DecoraShaderCommon.h) require explicit dependency on Metal compilation step
5. ✅ **Trust OpenJDK phase ordering** - gensrc always completes before libs for the same module

---

## File Generation Summary

### Total Generated Files

- **Temp core classes**: 1,874 .class files
- **ANTLR parser**: 6 .java files
- **Compiled shaders**: 602 .java files
- **Metal shaders**: 93+ .air files
- **Headers**: 3 .h files (12,578 total lines)
- **Metal library**: 1 .metallib file
- **Final module shaders**: 539 resource files

### Final Module Contents

```
jdk/modules/javafx.graphics/
├── com/
│   └── sun/
│       ├── prism/
│       │   ├── d3d/hlsl/*.obj        (DirectX shaders, Windows only)
│       │   ├── es2/glsl/*.frag       (OpenGL fragment shaders, macOS/iOS/Linux)
│       │   └── mtl/msl/jfxshaders.metallib  (Compiled Metal library, macOS/iOS only)
│       └── scenario/effect/impl/
│           ├── es2/glsl/*.frag       (Effect fragment shaders, macOS/iOS/Linux)
│           ├── sw/java/*.class       (Software renderer, all platforms)
│           ├── sw/sse/*.class        (SSE optimized, all platforms)
│           ├── prism/ps/*.class      (Prism pipeline, all platforms)
│           ├── prism/sw/*.class      (Prism software, all platforms)
│           └── hw/
│               ├── d3d/hlsl/*.obj    (DirectX shaders, Windows only)
│               └── mtl/*.class       (Metal shader wrappers, macOS/iOS only)
├── javafx/
│   └── (other javafx.graphics classes)
└── module-info.class

Note: .metal and .hlsl source files are NOT included in the module.
They are intermediate files used only during native compilation to
produce .air files (Metal) or .obj files (DirectX), which are then
linked into the metallib or the native library.
```

---

## References

- **Source**: `openjdk-ext/src/javafx.graphics/Gensrc.gmk`
- **Related**: `Java.gmk`, `Lib.gmk`
- **Original bash script**: `jpereda-jfx/scripts/script.sh`
- **OpenJDK Build System**: `make/common/`, `make/Main.gmk`

---

*Last Updated: February 17, 2026*
*JavaFX Version: 27*
*OpenJDK Mobile Build System*

