
# Tiger Compiler (Subset)

A single-pass compiler for a subset of the Tiger language. Takes a `.tgr` source file and produces a symbol table, three-address code (TAC), liveness analysis, and register-allocated TAC using Chaitin's graph-coloring algorithm.

## Pipeline

```
Source (.tgr)
    │
    ▼
Lexer (flex)  ──►  Parser (bison)  ──►  AST
                                          │
                                          ▼
                                    Symbol Table
                                          │
                                          ▼
                                   TAC Generation
                                          │
                                          ▼
                                   Basic Blocks
                                          │
                                          ▼
                              Local Optimization
                          (constant folding + copy propagation)
                                          │
                                          ▼
                               Liveness Analysis
                             (backward dataflow, iterated)
                                          │
                                          ▼
                              Interference Graph
                                          │
                                          ▼
                           Chaitin Register Allocation
                                  (8 registers)
                                          │
                                          ▼
                          Register-Allocated TAC (stdout)
```

## Files

| File | Description |
|------|-------------|
| `tiger_lexer.l` | Flex lexer — tokenizes Tiger source |
| `tiger_parser.y` | Bison parser — AST, symbol table, TAC generation, optimization, register allocation |

## Build

Requires `bison`, `flex`, and `gcc`.

```bash
bison -d tiger_parser.y
flex tiger_lexer.l
gcc -o tiger tiger_parser.tab.c lex.yy.c
```

On some systems you may need to link the flex runtime:

```bash
gcc -o tiger tiger_parser.tab.c lex.yy.c -lfl
```

## Usage

```bash
./tiger <input.tgr>
```

## Output

The compiler prints four sections to stdout:

**1. Symbol Table** — all declared variables and types with their kind, type name, and whether they are arrays.

**2. Three-Address Code** — unoptimized TAC emitted directly from the AST walk. Instructions use temporaries `t0`, `t1`, ... and labels `L0`, `L1`, ...

**3. Register Allocation Table** — each variable/temporary mapped to a register (`R0`–`R7`) or a spill slot (`_sp_N`) after Chaitin coloring.

**4. Liveness Table** — `live_in` and `live_out` sets for each basic block, used to build the interference graph.

**5. Register-Allocated TAC** — the TAC with all temporaries and variables replaced by their assigned registers or spill slots.

## Example

**Input (`test.tgr`):**
```
let
    type arr = array of int
    var x : int := 0
    var a := arr[5] of 0
in
    while x < 5 do
        if x = 3 then
            break
        else (
            a[x] := x + 1;
            x := x + 1
        )
end
```

**Output (abbreviated):**
```
===== Symbol Table =====
Name                 Kind     Type         IsArray
----                 ----     ----         -------
a                    var      arr          yes
arr                  type     int          yes
x                    var      int          no

===== Three-Address Code =====
    type arr = array of int
    var x : int
    t0 = 0
    x = t0
    var a : arr
    t1 = 5
    t2 = 0
    t3 = arr[t1] of t2
    a = t3
L0:
    t4 = 5
    t5 = x < t4
    iffalse t5 goto L1
    ...

===== Register Allocation (Chaitin, 8 regs) =====
Variable             Assignment
--------             ----------
x                    R0
a                    R1
t0                   R0
...

===== Register-Allocated TAC =====
    var x : int
    R0 = 0
    ...
L0:
    R1 = R0 < 5
    iffalse R1 goto L1
    ...
```

## Supported Language Features

| Feature | Syntax |
|---------|--------|
| Integer literals | `42` |
| String literals | `"hello"` |
| Nil | `nil` |
| Arithmetic | `+`, `-`, `*`, `/` |
| Comparison | `=`, `<>`, `<`, `<=`, `>`, `>=` |
| Boolean | `&`, `\|` |
| Unary negation | `-expr` |
| Variable declaration | `var x : int := 0` |
| Type-inferred declaration | `var a := arr[5] of 0` |
| Array type declaration | `type arr = array of int` |
| Array creation | `arr[n] of v` |
| Array access | `a[i]` |
| Array assignment | `a[i] := expr` |
| Assignment | `x := expr` |
| Sequencing | `(e1; e2; ...)` |
| If-then | `if cond then expr` |
| If-then-else | `if cond then expr else expr` |
| While loop | `while cond do expr` |
| Break | `break` |
| Let block | `let decls in expr end` |
| Comments | `/* ... */` |

## Implementation Details

### AST

Nodes are allocated with `mk(NodeKind)`. Each node carries an integer value (`ival`), a string value (`sval`), an operator string (`op`), and up to three children (`c1`, `c2`, `c3`).

### Symbol Table

A hash table (`SYM_HASH = 64` buckets) storing each declared name with its kind (`var`/`type`), type name, and `is_array` flag. When a variable is declared without an explicit type annotation (e.g. `var a := arr[5] of 0`), the type is inferred from the array-create initializer.

### TAC Generation

A single recursive walk over the AST fills a flat `TACInstr` array (max 65536 instructions). Each instruction records its kind and up to three string operands (`dst`, `src1`, `src2`). Temporaries are named `t0`, `t1`, ...; labels `L0`, `L1`, ...

### Basic Block Partitioning

Standard leader identification: instruction 0, any branch target, and any instruction immediately following a branch is a leader. Successor edges are wired for `GOTO` (one successor) and `IFFALSE` (fall-through + branch target).

### Local Optimization

A forward pass over each basic block maintains a copy/constant environment. Two transformations are applied:

- **Constant folding** — a `BINOP` or `NEG` with all-constant operands is replaced by a single `ASSIGN` of the result.
- **Copy propagation** — uses of a variable that was most recently assigned a constant or another variable are substituted with that value.

### Liveness Analysis

Backward dataflow iterated to fixpoint over the block CFG:

```
live_out[B] = ∪ live_in[succ(B)]
live_in[B]  = use[B] ∪ (live_out[B] − def[B])
```

Live sets are represented as bitsets (`uint32_t[]`) over all variable names seen. The `instr_use_def` function maps each TAC instruction kind to its defined variable and used variables.

### Interference Graph

At each definition point in a backward scan, the defined variable is made to interfere with every variable currently in the live set. The graph is stored as a `uint8_t` adjacency matrix.

### Chaitin Register Allocation

Simplified Chaitin coloring with 8 registers (`R0`–`R7`):

1. **Simplify** — repeatedly push nodes with degree < 8 onto a stack and remove them from the graph.
2. **Spill** — any node remaining after simplify (degree ≥ 8 in all configurations) is marked as spilled and assigned a stack slot `_sp_N`.
3. **Select** — pop the stack, assign each node the lowest color not used by its already-colored neighbors.
4. **Iterate** — if spills occurred, insert `COPY` load/store instructions around each spilled variable's uses and defs, then repeat the full pipeline (block partition → liveness → interference → color) until no new spills arise.
