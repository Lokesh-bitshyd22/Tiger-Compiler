%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>

typedef enum {
    N_INT, N_STR, N_NIL, N_ID,
    N_NEG,
    N_BINOP,
    N_ASSIGN,
    N_ARRAY_CREATE,
    N_IF,
    N_WHILE,
    N_BREAK,
    N_SEQ,
    N_LET,
    N_ARR_ACCESS,
    N_VAR_DECL,
    N_TYPE_DECL,
    N_DECL_LIST,
    N_NOP
} NodeKind;

typedef struct ASTNode {
    NodeKind kind;
    int    ival;
    char  *sval;
    char  *op;
    struct ASTNode *c1, *c2, *c3;
} ASTNode;

ASTNode* mk(NodeKind k) {
    ASTNode *n = calloc(1, sizeof(ASTNode));
    n->kind = k;
    return n;
}

typedef enum { SYM_VAR, SYM_TYPE } SymKind;

typedef struct SymEntry {
    char     *name;
    SymKind   kind;
    char     *type_name;
    int       is_array;
    struct SymEntry *next;
} SymEntry;

#define SYM_HASH 64
static SymEntry *sym_table[SYM_HASH];

static unsigned sym_hash(const char *s) {
    unsigned h = 0;
    while (*s) h = h * 31 + (unsigned char)*s++;
    return h % SYM_HASH;
}

static void sym_insert(const char *name, SymKind kind, const char *type_name, int is_array) {
    unsigned h = sym_hash(name);
    SymEntry *e = calloc(1, sizeof(SymEntry));
    e->name      = strdup(name);
    e->kind      = kind;
    e->type_name = type_name ? strdup(type_name) : NULL;
    e->is_array  = is_array;
    e->next      = sym_table[h];
    sym_table[h] = e;
}

static SymEntry* sym_lookup(const char *name) {
    unsigned h = sym_hash(name);
    for (SymEntry *e = sym_table[h]; e; e = e->next)
        if (strcmp(e->name, name) == 0) return e;
    return NULL;
}

static void sym_print(void) {
    printf("\n===== Symbol Table =====\n");
    printf("%-20s %-8s %-12s %s\n", "Name", "Kind", "Type", "IsArray");
    printf("%-20s %-8s %-12s %s\n", "----", "----", "----", "-------");
    for (int i = 0; i < SYM_HASH; i++) {
        for (SymEntry *e = sym_table[i]; e; e = e->next) {
            printf("%-20s %-8s %-12s %s\n",
                e->name,
                e->kind == SYM_VAR ? "var" : "type",
                e->type_name ? e->type_name : "?",
                e->is_array ? "yes" : "no");
        }
    }
}

typedef enum {
    TAC_ASSIGN,
    TAC_BINOP,
    TAC_NEG,
    TAC_COPY,
    TAC_LOAD_ARR,
    TAC_STORE_ARR,
    TAC_ARR_CREATE,
    TAC_IFFALSE,
    TAC_GOTO,
    TAC_LABEL,
    TAC_VAR_DECL,
    TAC_TYPE_DECL,
    TAC_NOP
} TACKind;

typedef struct {
    TACKind  kind;
    char    *dst;
    char    *src1;
    char    *src2;
    char    *op;
    char    *extra;
} TACInstr;

#define MAX_INSTRS 65536
static TACInstr instrs[MAX_INSTRS];
static int      n_instrs = 0;

static void tac_emit(TACKind kind, const char *dst, const char *src1,
                     const char *src2, const char *op, const char *extra) {
    if (n_instrs >= MAX_INSTRS) { fprintf(stderr, "TAC buffer full\n"); exit(1); }
    TACInstr *i  = &instrs[n_instrs++];
    i->kind  = kind;
    i->dst   = dst   ? strdup(dst)   : NULL;
    i->src1  = src1  ? strdup(src1)  : NULL;
    i->src2  = src2  ? strdup(src2)  : NULL;
    i->op    = op    ? strdup(op)    : NULL;
    i->extra = extra ? strdup(extra) : NULL;
}

static int tc = 0, lc = 0;

static char* break_stack[64];
static int   break_sp = 0;
void push_break(char *l) { break_stack[break_sp++] = l; }
void pop_break(void)     { break_sp--; }
char* cur_break(void)    { return break_sp > 0 ? break_stack[break_sp-1] : NULL; }

static char* nt(void) { char *t = malloc(16); sprintf(t, "t%d", tc++); return t; }
static char* nl(void) { char *l = malloc(16); sprintf(l, "L%d", lc++); return l; }

char* gen(ASTNode *n);
void  gen_decl(ASTNode *n);

char* gen(ASTNode *n) {
    if (!n) return strdup("0");
    char *t, *a, *b;
    switch (n->kind) {
    case N_INT:
        t = nt();
        tac_emit(TAC_ASSIGN, t, NULL, NULL, NULL, NULL);
        { char buf[32]; sprintf(buf, "%d", n->ival);
          instrs[n_instrs-1].src1 = strdup(buf); }
        return t;
    case N_STR:
        t = nt();
        { char buf[4096]; snprintf(buf, sizeof(buf), "\"%s\"", n->sval);
          tac_emit(TAC_ASSIGN, t, buf, NULL, NULL, NULL); }
        return t;
    case N_NIL:
        t = nt();
        tac_emit(TAC_ASSIGN, t, "nil", NULL, NULL, NULL);
        return t;
    case N_ID:
        return strdup(n->sval);
    case N_NEG:
        a = gen(n->c1); t = nt();
        tac_emit(TAC_NEG, t, a, NULL, NULL, NULL);
        free(a); return t;
    case N_BINOP:
        a = gen(n->c1); b = gen(n->c2); t = nt();
        tac_emit(TAC_BINOP, t, a, b, n->op, NULL);
        free(a); free(b); return t;
    case N_ASSIGN:
        if (n->c1->kind == N_ARR_ACCESS) {
            a = strdup(n->c1->sval);  /* array name from lvalue */
            b = gen(n->c1->c1);       /* index expression */
            char *rv = gen(n->c2);
            tac_emit(TAC_STORE_ARR, a, rv, b, NULL, NULL);
            free(a); free(b);
            return rv;
        } else {
            a = gen(n->c1); b = gen(n->c2);
            tac_emit(TAC_COPY, a, b, NULL, NULL, NULL);
            free(b); return a;
        }
    case N_ARRAY_CREATE:
        a = gen(n->c1); b = gen(n->c2); t = nt();
        tac_emit(TAC_ARR_CREATE, t, a, b, NULL, n->sval);
        free(a); free(b); return t;
    case N_IF: {
        a = gen(n->c1);
        if (n->c3) {
            char *le = nl(), *lend = nl();
            t = nt();
            tac_emit(TAC_IFFALSE, a, le, NULL, NULL, NULL);
            b = gen(n->c2);
            tac_emit(TAC_COPY, t, b, NULL, NULL, NULL);
            tac_emit(TAC_GOTO, lend, NULL, NULL, NULL, NULL);
            tac_emit(TAC_LABEL, le, NULL, NULL, NULL, NULL);
            char *ev = gen(n->c3);
            tac_emit(TAC_COPY, t, ev, NULL, NULL, NULL);
            tac_emit(TAC_LABEL, lend, NULL, NULL, NULL, NULL);
            free(a); free(b); free(ev);
            return t;
        } else {
            char *lend = nl();
            tac_emit(TAC_IFFALSE, a, lend, NULL, NULL, NULL);
            b = gen(n->c2);
            tac_emit(TAC_LABEL, lend, NULL, NULL, NULL, NULL);
            free(a); return b;
        }
    }
    case N_WHILE: {
        char *ls = nl(), *le = nl();
        push_break(le);
        tac_emit(TAC_LABEL, ls, NULL, NULL, NULL, NULL);
        a = gen(n->c1);
        tac_emit(TAC_IFFALSE, a, le, NULL, NULL, NULL);
        b = gen(n->c2);
        tac_emit(TAC_GOTO, ls, NULL, NULL, NULL, NULL);
        tac_emit(TAC_LABEL, le, NULL, NULL, NULL, NULL);
        pop_break();
        free(a); free(b);
        t = nt(); tac_emit(TAC_ASSIGN, t, "0", NULL, NULL, NULL); return t;
    }
    case N_BREAK: {
        char *bl = cur_break();
        if (!bl) { fprintf(stderr, "Error: break used outside loop\n"); exit(1); }
        tac_emit(TAC_GOTO, bl, NULL, NULL, NULL, NULL);
        t = nt(); tac_emit(TAC_ASSIGN, t, "0", NULL, NULL, NULL); return t;
    }
    case N_SEQ:
        a = gen(n->c1); free(a);
        return gen(n->c2);
    case N_LET:
        gen_decl(n->c1);
        return gen(n->c2);
    case N_ARR_ACCESS:
        a = strdup(n->sval);  /* array name */
        b = gen(n->c1);       /* index expression */
        t = nt();
        tac_emit(TAC_LOAD_ARR, t, a, b, NULL, NULL);
        free(a); free(b); return t;
    case N_NOP:
        t = nt(); tac_emit(TAC_ASSIGN, t, "0", NULL, NULL, NULL); return t;
    default:
        return strdup("???");
    }
}

void gen_decl(ASTNode *n) {
    if (!n) return;
    char *v;
    switch (n->kind) {
    case N_DECL_LIST:
        gen_decl(n->c1); gen_decl(n->c2); break;
    case N_VAR_DECL: {
        /* Infer type from initializer when no explicit annotation is given
           (var x := arr[n] of v  =>  c1 is NULL, type comes from c2->sval). */
        const char *tname;
        if (n->c1 && n->c1->sval)
            tname = n->c1->sval;
        else if (n->c2 && n->c2->kind == N_ARRAY_CREATE && n->c2->sval)
            tname = n->c2->sval;
        else
            tname = "?";
        int is_arr = (sym_lookup(tname) && sym_lookup(tname)->is_array);
        sym_insert(n->sval, SYM_VAR, tname, is_arr);
        tac_emit(TAC_VAR_DECL, n->sval, tname, NULL, NULL, NULL);
        if (n->c2) { v = gen(n->c2); tac_emit(TAC_COPY, n->sval, v, NULL, NULL, NULL); free(v); }
        break;
    }
    case N_TYPE_DECL: {
        const char *base = n->c1 ? n->c1->sval : "?";
        sym_insert(n->sval, SYM_TYPE, base, 1);
        tac_emit(TAC_TYPE_DECL, n->sval, base, NULL, NULL, NULL);
        break;
    }
    }
}

#define MAX_BLOCKS  4096

typedef struct {
    int  start;
    int  end;
    int  succ[2];
    int  n_succ;
} BasicBlock;

static BasicBlock blocks[MAX_BLOCKS];
static int        n_blocks = 0;

static int block_of_label(const char *label) {
    for (int i = 0; i < n_blocks; i++) {
        int s = blocks[i].start;
        if (instrs[s].kind == TAC_LABEL && strcmp(instrs[s].dst, label) == 0)
            return i;
    }
    return -1;
}

static void build_blocks(void) {
    char is_leader[MAX_INSTRS];
    memset(is_leader, 0, n_instrs);
    if (n_instrs > 0) is_leader[0] = 1;
    for (int i = 0; i < n_instrs; i++) {
        TACKind k = instrs[i].kind;
        if (k == TAC_GOTO || k == TAC_IFFALSE) {
            if (i+1 < n_instrs) is_leader[i+1] = 1;
        }
        if (k == TAC_LABEL) is_leader[i] = 1;
    }

    n_blocks = 0;
    for (int i = 0; i < n_instrs; i++) {
        if (is_leader[i]) {
            if (n_blocks > 0) blocks[n_blocks-1].end = i;
            blocks[n_blocks].start   = i;
            blocks[n_blocks].end     = n_instrs;
            blocks[n_blocks].n_succ  = 0;
            blocks[n_blocks].succ[0] = blocks[n_blocks].succ[1] = -1;
            n_blocks++;
        }
    }

    for (int b = 0; b < n_blocks; b++) {
        int last = blocks[b].end - 1;
        TACInstr *ti = &instrs[last];
        if (ti->kind == TAC_GOTO) {
            int t = block_of_label(ti->dst);
            if (t >= 0) { blocks[b].succ[0] = t; blocks[b].n_succ = 1; }
        } else if (ti->kind == TAC_IFFALSE) {
            if (b+1 < n_blocks) { blocks[b].succ[0] = b+1; blocks[b].n_succ = 1; }
            int t = block_of_label(ti->src1);
            if (t >= 0) { blocks[b].succ[blocks[b].n_succ] = t; blocks[b].n_succ++; }
        } else {
            if (b+1 < n_blocks) { blocks[b].succ[0] = b+1; blocks[b].n_succ = 1; }
        }
    }
}

static int is_const(const char *s, int *val) {
    if (!s) return 0;
    char *end;
    long v = strtol(s, &end, 10);
    if (end != s && *end == '\0') { *val = (int)v; return 1; }
    return 0;
}

#define ENV_CAP 256
typedef struct { char *var; char *val; } EnvEntry;
static EnvEntry env[ENV_CAP];
static int env_n = 0;

static void env_clear(void) { env_n = 0; }

static const char* env_lookup(const char *var) {
    for (int i = env_n-1; i >= 0; i--)
        if (strcmp(env[i].var, var) == 0) return env[i].val;
    return NULL;
}

static void env_set(const char *var, const char *val) {
    for (int i = 0; i < env_n; i++)
        if (strcmp(env[i].var, var) == 0) { free(env[i].val); env[i].val = strdup(val); return; }
    if (env_n < ENV_CAP) { env[env_n].var = strdup(var); env[env_n].val = strdup(val); env_n++; }
}

static char* subst(const char *name) {
    if (!name) return NULL;
    const char *v = env_lookup(name);
    return strdup(v ? v : name);
}

static void local_optimize(void) {
    for (int b = 0; b < n_blocks; b++) {
        env_clear();
        for (int i = blocks[b].start; i < blocks[b].end; i++) {
            TACInstr *ti = &instrs[i];
            if (ti->src1) { char *s = subst(ti->src1); free(ti->src1); ti->src1 = s; }
            if (ti->src2) { char *s = subst(ti->src2); free(ti->src2); ti->src2 = s; }

            switch (ti->kind) {
            case TAC_ASSIGN:
                if (ti->src1 && ti->dst) env_set(ti->dst, ti->src1);
                break;
            case TAC_COPY:
                if (ti->src1 && ti->dst) env_set(ti->dst, ti->src1);
                break;
            case TAC_BINOP: {
                int v1, v2;
                if (is_const(ti->src1, &v1) && is_const(ti->src2, &v2) && ti->op) {
                    int res = 0;
                    if      (strcmp(ti->op,"+")==0)  res = v1+v2;
                    else if (strcmp(ti->op,"-")==0)  res = v1-v2;
                    else if (strcmp(ti->op,"*")==0)  res = v1*v2;
                    else if (strcmp(ti->op,"/")==0 && v2!=0) res = v1/v2;
                    else if (strcmp(ti->op,"==")==0) res = v1==v2;
                    else if (strcmp(ti->op,"!=")==0) res = v1!=v2;
                    else if (strcmp(ti->op,"<")==0)  res = v1<v2;
                    else if (strcmp(ti->op,"<=")==0) res = v1<=v2;
                    else if (strcmp(ti->op,">")==0)  res = v1>v2;
                    else if (strcmp(ti->op,">=")==0) res = v1>=v2;
                    else break;
                    char buf[32]; sprintf(buf, "%d", res);
                    free(ti->src1); free(ti->src2); free(ti->op);
                    ti->kind = TAC_ASSIGN;
                    ti->src1 = strdup(buf); ti->src2 = NULL; ti->op = NULL;
                    env_set(ti->dst, buf);
                }
                break;
            }
            case TAC_NEG: {
                int v1;
                if (is_const(ti->src1, &v1)) {
                    char buf[32]; sprintf(buf, "%d", -v1);
                    free(ti->src1);
                    ti->kind = TAC_ASSIGN; ti->src1 = strdup(buf);
                    env_set(ti->dst, buf);
                }
                break;
            }
            default: break;
            }
        }
    }
}

#define MAX_VARS  1024

typedef struct { char *name; } VarEntry;

static VarEntry  var_pool[MAX_VARS];
static int       n_vars = 0;

static int var_id(const char *name) {
    if (!name || name[0] == '\0') return -1;
    char *end; strtol(name, &end, 10);
    if (end != name && *end == '\0') return -1;
    if (name[0] == '"') return -1;
    if (strcmp(name, "nil") == 0) return -1;
    for (int i = 0; i < n_vars; i++)
        if (strcmp(var_pool[i].name, name) == 0) return i;
    if (n_vars >= MAX_VARS) return -1;
    var_pool[n_vars].name = strdup(name);
    return n_vars++;
}

#define BITS_PER_WORD 32
#define BITSET_WORDS  ((MAX_VARS + BITS_PER_WORD - 1) / BITS_PER_WORD)

typedef uint32_t Bitset[BITSET_WORDS];

static void bs_clear(Bitset b)              { memset(b,0,sizeof(Bitset)); }
static void bs_set  (Bitset b, int i)       { if(i>=0) b[i/32] |=  (1u<<(i%32)); }
static void bs_clr  (Bitset b, int i)       { if(i>=0) b[i/32] &= ~(1u<<(i%32)); }
static int  bs_test (const Bitset b, int i) { return (i>=0) && (b[i/32]>>(i%32))&1; }
static int  bs_union(Bitset dst, const Bitset a, const Bitset b) {
    int changed = 0;
    for (int w = 0; w < BITSET_WORDS; w++) {
        uint32_t nv = a[w]|b[w];
        if (nv != dst[w]) { dst[w]=nv; changed=1; }
    }
    return changed;
}
static void bs_copy(Bitset dst, const Bitset src) { memcpy(dst,src,sizeof(Bitset)); }

static Bitset *live_in_blk;
static Bitset *live_out_blk;

static void instr_use_def(int idx, int *uses, int *n_use, int *def) {
    TACInstr *ti = &instrs[idx];
    *n_use = 0; *def = -1;
    switch (ti->kind) {
    case TAC_ASSIGN:
        *def = var_id(ti->dst);
        break;
    case TAC_COPY:
        uses[(*n_use)++] = var_id(ti->src1);
        *def = var_id(ti->dst);
        break;
    case TAC_BINOP:
        uses[(*n_use)++] = var_id(ti->src1);
        uses[(*n_use)++] = var_id(ti->src2);
        *def = var_id(ti->dst);
        break;
    case TAC_NEG:
        uses[(*n_use)++] = var_id(ti->src1);
        *def = var_id(ti->dst);
        break;
    case TAC_LOAD_ARR:
        uses[(*n_use)++] = var_id(ti->src1);  /* base */
        uses[(*n_use)++] = var_id(ti->src2);  /* index */
        *def = var_id(ti->dst);
        break;
    case TAC_STORE_ARR:
        uses[(*n_use)++] = var_id(ti->dst);   /* base array */
        uses[(*n_use)++] = var_id(ti->src1);  /* value */
        uses[(*n_use)++] = var_id(ti->src2);  /* index */
        break;
    case TAC_ARR_CREATE:
        uses[(*n_use)++] = var_id(ti->src1);  /* size */
        uses[(*n_use)++] = var_id(ti->src2);  /* init value */
        *def = var_id(ti->dst);
        break;
    case TAC_IFFALSE:
        uses[(*n_use)++] = var_id(ti->dst);   /* condition */
        break;
    case TAC_GOTO:
    case TAC_LABEL:
    case TAC_VAR_DECL:
    case TAC_TYPE_DECL:
    case TAC_NOP:
        break;
    }
}

static void liveness_analysis(void) {
    live_in_blk  = calloc(n_blocks, sizeof(Bitset));
    live_out_blk = calloc(n_blocks, sizeof(Bitset));

    int changed = 1;
    while (changed) {
        changed = 0;
        for (int b = n_blocks-1; b >= 0; b--) {
            Bitset new_out;
            bs_clear(new_out);
            for (int s = 0; s < blocks[b].n_succ; s++)
                bs_union(new_out, new_out, live_in_blk[blocks[b].succ[s]]);

            Bitset live;
            bs_copy(live, new_out);
            for (int i = blocks[b].end-1; i >= blocks[b].start; i--) {
                int uses[4], n_use, def;
                instr_use_def(i, uses, &n_use, &def);
                if (def >= 0) bs_clr(live, def);
                for (int u = 0; u < n_use; u++)
                    if (uses[u] >= 0) bs_set(live, uses[u]);
            }

            if (bs_union(live_in_blk[b], live_in_blk[b], live) ||
                bs_union(live_out_blk[b], live_out_blk[b], new_out))
                changed = 1;
        }
    }
}

static void liveness_print(void) {
    printf("\n===== Liveness Table =====\n");
    for (int b = 0; b < n_blocks; b++) {
        printf("Block %d (instrs %d-%d):\n", b, blocks[b].start, blocks[b].end-1);
        printf("  live_in : ");
        for (int v = 0; v < n_vars; v++)
            if (bs_test(live_in_blk[b], v)) printf("%s ", var_pool[v].name);
        printf("\n  live_out: ");
        for (int v = 0; v < n_vars; v++)
            if (bs_test(live_out_blk[b], v)) printf("%s ", var_pool[v].name);
        printf("\n");
    }
}

#define NUM_REGS  8

static uint8_t interfere[MAX_VARS][MAX_VARS];
static int     color[MAX_VARS];

static void build_interference(void) {
    memset(interfere, 0, sizeof(interfere));
    for (int b = 0; b < n_blocks; b++) {
        Bitset live;
        bs_copy(live, live_out_blk[b]);
        for (int i = blocks[b].end-1; i >= blocks[b].start; i--) {
            int uses[4], n_use, def;
            instr_use_def(i, uses, &n_use, &def);
            if (def >= 0) {
                for (int v = 0; v < n_vars; v++)
                    if (v != def && bs_test(live, v))
                        interfere[def][v] = interfere[v][def] = 1;
                bs_clr(live, def);
            }
            for (int u = 0; u < n_use; u++)
                if (uses[u] >= 0) bs_set(live, uses[u]);
        }
    }
}

static int stk[MAX_VARS], stk_top;
static int removed[MAX_VARS];
static int degree[MAX_VARS];

static void compute_degrees(void) {
    for (int i = 0; i < n_vars; i++) {
        degree[i] = 0;
        if (removed[i]) continue;
        for (int j = 0; j < n_vars; j++)
            if (!removed[j] && interfere[i][j]) degree[i]++;
    }
}

static int spill_count = 0;
static int spill_slot[MAX_VARS];

static void insert_spill_code(void) {
    TACInstr *new_instrs = calloc(MAX_INSTRS * 2, sizeof(TACInstr));
    int new_n = 0;

    for (int i = 0; i < n_instrs; i++) {
        TACInstr *ti = &instrs[i];
        int uses[4], n_use, def;
        instr_use_def(i, uses, &n_use, &def);

        for (int u = 0; u < n_use; u++) {
            int v = uses[u];
            if (v < 0 || color[v] != -2) continue;
            char spname[32]; sprintf(spname, "_sp_%d", spill_slot[v]);
            TACInstr ni = {TAC_COPY, strdup(var_pool[v].name), strdup(spname), NULL, NULL, NULL};
            new_instrs[new_n++] = ni;
        }

        new_instrs[new_n++] = *ti;

        if (def >= 0 && color[def] == -2) {
            char spname[32]; sprintf(spname, "_sp_%d", spill_slot[def]);
            TACInstr ni = {TAC_COPY, strdup(spname), strdup(var_pool[def].name), NULL, NULL, NULL};
            new_instrs[new_n++] = ni;
        }
    }

    memcpy(instrs, new_instrs, new_n * sizeof(TACInstr));
    n_instrs = new_n;
    free(new_instrs);
}

static void chaitin_color(void) {
    int max_rounds = n_vars + 1;

    for (int round = 0; round < max_rounds; round++) {
        memset(color,   -1, sizeof(color));
        memset(removed,  0, sizeof(removed));
        stk_top = 0;

        int pushed;
        do {
            pushed = 0;
            compute_degrees();
            for (int i = 0; i < n_vars; i++) {
                if (!removed[i] && degree[i] < NUM_REGS) {
                    stk[stk_top++] = i;
                    removed[i] = 1;
                    pushed = 1;
                    compute_degrees();
                }
            }
        } while (pushed);

        int spilled_this_round = 0;
        for (int i = 0; i < n_vars; i++) {
            if (!removed[i]) {
                color[i] = -2;
                if (spill_slot[i] < 0) { spill_slot[i] = spill_count++; }
                spilled_this_round = 1;
                removed[i] = 1;
            }
        }

        while (stk_top > 0) {
            int v = stk[--stk_top];
            uint8_t used[NUM_REGS];
            memset(used, 0, NUM_REGS);
            for (int j = 0; j < n_vars; j++)
                if (interfere[v][j] && color[j] >= 0 && color[j] < NUM_REGS)
                    used[color[j]] = 1;
            int c = -1;
            for (int r = 0; r < NUM_REGS; r++)
                if (!used[r]) { c = r; break; }
            color[v] = (c >= 0) ? c : -2;
            if (color[v] == -2 && spill_slot[v] < 0)
                spill_slot[v] = spill_count++;
        }

        if (!spilled_this_round) break;

        insert_spill_code();
        n_vars = 0;
        memset(spill_slot, -1, sizeof(spill_slot));
        memset(interfere, 0, sizeof(interfere));
        build_blocks();
        liveness_analysis();
        build_interference();
    }
}

static void regalloc_run(void) {
    memset(spill_slot, -1, sizeof(spill_slot));
    build_blocks();
    liveness_analysis();
    build_interference();
    chaitin_color();
}

static const char* reg_name(int r) {
    static const char *names[NUM_REGS] = {
        "R0","R1","R2","R3","R4","R5","R6","R7"
    };
    return (r >= 0 && r < NUM_REGS) ? names[r] : "??";
}

static const char* resolve(const char *name, char *buf) {
    if (!name) return "?";
    int v = -1;
    for (int i = 0; i < n_vars; i++)
        if (strcmp(var_pool[i].name, name) == 0) { v = i; break; }
    if (v < 0) return name;
    if (color[v] == -2) { sprintf(buf, "_sp_%d", spill_slot[v]); return buf; }
    if (color[v] >= 0)  return reg_name(color[v]);
    return name;
}

static void print_tac_raw(void) {
    printf("\n===== Three-Address Code =====\n");
    for (int i = 0; i < n_instrs; i++) {
        TACInstr *ti = &instrs[i];
        switch (ti->kind) {
        case TAC_ASSIGN:    printf("    %s = %s\n",           ti->dst, ti->src1); break;
        case TAC_COPY:      printf("    %s = %s\n",           ti->dst, ti->src1); break;
        case TAC_BINOP:     printf("    %s = %s %s %s\n",     ti->dst, ti->src1, ti->op, ti->src2); break;
        case TAC_NEG:       printf("    %s = -%s\n",          ti->dst, ti->src1); break;
        case TAC_LOAD_ARR:  printf("    %s = %s[%s]\n",       ti->dst, ti->src1, ti->src2); break;
        case TAC_STORE_ARR: printf("    %s[%s] = %s\n",       ti->dst, ti->src2, ti->src1); break;
        case TAC_ARR_CREATE:printf("    %s = %s[%s] of %s\n", ti->dst, ti->extra ? ti->extra : "?", ti->src1, ti->src2); break;
        case TAC_IFFALSE:   printf("    iffalse %s goto %s\n",ti->dst, ti->src1 ? ti->src1 : "?"); break;
        case TAC_GOTO:      printf("    goto %s\n",            ti->dst); break;
        case TAC_LABEL:     printf("%s:\n",                    ti->dst); break;
        case TAC_VAR_DECL:  printf("    var %s : %s\n",        ti->dst, ti->src1 ? ti->src1 : "?"); break;
        case TAC_TYPE_DECL: printf("    type %s = array of %s\n", ti->dst, ti->src1 ? ti->src1 : "?"); break;
        case TAC_NOP:       printf("    nop\n"); break;
        }
    }
}

static void print_reg_alloc(void) {
    printf("\n===== Register Allocation (Chaitin, %d regs) =====\n", NUM_REGS);
    printf("%-20s %s\n", "Variable", "Assignment");
    printf("%-20s %s\n", "--------", "----------");
    for (int v = 0; v < n_vars; v++) {
        if (color[v] == -2)
            printf("%-20s _sp_%d (spilled)\n", var_pool[v].name, spill_slot[v]);
        else if (color[v] >= 0)
            printf("%-20s %s\n", var_pool[v].name, reg_name(color[v]));
        else
            printf("%-20s (unused)\n", var_pool[v].name);
    }
}

static void print_tac_allocated(void) {
    char b1[32], b2[32], b3[32];
    printf("\n===== Register-Allocated TAC =====\n");
    for (int i = 0; i < n_instrs; i++) {
        TACInstr *ti = &instrs[i];
        const char *d  = ti->dst  ? resolve(ti->dst,  b1) : NULL;
        const char *s1 = ti->src1 ? resolve(ti->src1, b2) : NULL;
        const char *s2 = ti->src2 ? resolve(ti->src2, b3) : NULL;
        switch (ti->kind) {
        case TAC_ASSIGN:    printf("    %s = %s\n",           d, s1); break;
        case TAC_COPY:      printf("    %s = %s\n",           d, s1); break;
        case TAC_BINOP:     printf("    %s = %s %s %s\n",     d, s1, ti->op, s2); break;
        case TAC_NEG:       printf("    %s = -%s\n",          d, s1); break;
        case TAC_LOAD_ARR:  printf("    %s = %s[%s]\n",       d, s1, s2); break;
        case TAC_STORE_ARR: printf("    %s[%s] = %s\n",       d, s2, s1); break;
        case TAC_ARR_CREATE:printf("    %s = %s[%s] of %s\n", d, ti->extra ? ti->extra : "?", s1, s2); break;
        case TAC_IFFALSE:   printf("    iffalse %s goto %s\n",d, ti->src1 ? ti->src1 : "?"); break;
        case TAC_GOTO:      printf("    goto %s\n",            d); break;
        case TAC_LABEL:     printf("%s:\n",                    d); break;
        case TAC_VAR_DECL:  printf("    var %s : %s\n",        ti->dst, ti->src1 ? ti->src1 : "?"); break;
        case TAC_TYPE_DECL: printf("    type %s = array of %s\n", ti->dst, ti->src1 ? ti->src1 : "?"); break;
        case TAC_NOP:       printf("    nop\n"); break;
        }
    }
}

extern int yylex();
extern int yylineno;
extern FILE *yyin;
void yyerror(const char *s);
static ASTNode *ast_root = NULL;

%}

%union {
    int      ival;
    char    *sval;
    struct ASTNode *node;
}

%token <ival> INTEGER_LITERAL
%token <sval> STRING_LITERAL IDENTIFIER
%token ARRAY BREAK DO ELSE END IF IN LET NIL OF THEN TYPE VAR WHILE
%token TYPE_INT TYPE_STRING
%token ASSIGN NEQ LE GE LT GT EQ
%token PLUS MINUS TIMES DIVIDE AND OR
%token LPAREN RPAREN LBRACKET RBRACKET COLON SEMICOLON

%type <node> expr lvalue program expr_seq expr_seq_opt
%type <node> decl_list decl type_decl_list type_decl var_decl_list var_decl
%type <sval> type_id

%nonassoc ASSIGN
%left OR
%left AND
%nonassoc EQ NEQ LT LE GT GE
%left PLUS MINUS
%left TIMES DIVIDE
%right UMINUS

%nonassoc THEN
%nonassoc ELSE

%%

program
    : expr  { ast_root = $1; printf("Parsing successful!\n"); }
    ;

expr
    : INTEGER_LITERAL          { $$ = mk(N_INT); $$->ival = $1; }
    | STRING_LITERAL           { $$ = mk(N_STR); $$->sval = $1; }
    | NIL                      { $$ = mk(N_NIL); }
    | lvalue                   { $$ = $1; }
    | MINUS expr %prec UMINUS  { $$ = mk(N_NEG); $$->c1 = $2; }
    | expr PLUS   expr { $$ = mk(N_BINOP); $$->op=strdup("+");  $$->c1=$1; $$->c2=$3; }
    | expr MINUS  expr { $$ = mk(N_BINOP); $$->op=strdup("-");  $$->c1=$1; $$->c2=$3; }
    | expr TIMES  expr { $$ = mk(N_BINOP); $$->op=strdup("*");  $$->c1=$1; $$->c2=$3; }
    | expr DIVIDE expr { $$ = mk(N_BINOP); $$->op=strdup("/");  $$->c1=$1; $$->c2=$3; }
    | expr EQ     expr { $$ = mk(N_BINOP); $$->op=strdup("=="); $$->c1=$1; $$->c2=$3; }
    | expr NEQ    expr { $$ = mk(N_BINOP); $$->op=strdup("!="); $$->c1=$1; $$->c2=$3; }
    | expr LT     expr { $$ = mk(N_BINOP); $$->op=strdup("<");  $$->c1=$1; $$->c2=$3; }
    | expr LE     expr { $$ = mk(N_BINOP); $$->op=strdup("<="); $$->c1=$1; $$->c2=$3; }
    | expr GT     expr { $$ = mk(N_BINOP); $$->op=strdup(">");  $$->c1=$1; $$->c2=$3; }
    | expr GE     expr { $$ = mk(N_BINOP); $$->op=strdup(">="); $$->c1=$1; $$->c2=$3; }
    | expr AND    expr { $$ = mk(N_BINOP); $$->op=strdup("&");  $$->c1=$1; $$->c2=$3; }
    | expr OR     expr { $$ = mk(N_BINOP); $$->op=strdup("|");  $$->c1=$1; $$->c2=$3; }
    | lvalue ASSIGN expr {
        $$ = mk(N_ASSIGN); $$->c1 = $1; $$->c2 = $3;
    }
    | IDENTIFIER LBRACKET expr RBRACKET OF expr {
        $$ = mk(N_ARRAY_CREATE); $$->sval = $1; $$->c1 = $3; $$->c2 = $6;
    }
    | IF expr THEN expr %prec THEN {
        $$ = mk(N_IF); $$->c1=$2; $$->c2=$4; $$->c3=NULL;
    }
    | IF expr THEN expr ELSE expr {
        $$ = mk(N_IF); $$->c1=$2; $$->c2=$4; $$->c3=$6;
    }
    | WHILE expr DO expr {
        $$ = mk(N_WHILE); $$->c1=$2; $$->c2=$4;
    }
    | BREAK { $$ = mk(N_BREAK); }
    | LPAREN expr_seq_opt RPAREN { $$ = $2; }
    | LET decl_list IN expr_seq_opt END {
        $$ = mk(N_LET); $$->c1=$2; $$->c2=$4;
    }
    ;

expr_seq
    : expr                    { $$ = $1; }
    | expr_seq SEMICOLON expr { $$ = mk(N_SEQ); $$->c1=$1; $$->c2=$3; }
    ;

expr_seq_opt
    : expr_seq    { $$ = $1; }
    | /* empty */ { $$ = mk(N_NOP); }
    ;

lvalue
    : IDENTIFIER                              { $$ = mk(N_ID); $$->sval=$1; }
    | IDENTIFIER LBRACKET expr RBRACKET       { $$ = mk(N_ARR_ACCESS); $$->sval=$1; $$->c1=$3; }
    ;

decl_list
    : decl                { $$ = $1; }
    | decl_list decl      { $$ = mk(N_DECL_LIST); $$->c1=$1; $$->c2=$2; }
    ;

decl
    : TYPE type_decl_list { $$ = $2; }
    | VAR var_decl_list   { $$ = $2; }
    ;

type_decl_list
    : type_decl                { $$ = $1; }
    | type_decl_list type_decl { $$ = mk(N_DECL_LIST); $$->c1=$1; $$->c2=$2; }
    ;

type_decl
    : IDENTIFIER EQ ARRAY OF type_id {
        $$ = mk(N_TYPE_DECL);
        $$->sval = $1;
        $$->c1 = mk(N_NOP);
        $$->c1->sval = $5;
        $$->c2 = NULL;
    }
    ;

var_decl_list
    : var_decl                { $$ = $1; }
    | var_decl_list var_decl  { $$ = mk(N_DECL_LIST); $$->c1=$1; $$->c2=$2; }
    ;

var_decl
    : IDENTIFIER ASSIGN expr {
        $$ = mk(N_VAR_DECL);
        $$->sval = $1;
        $$->c1 = NULL;
        $$->c2 = $3;
    }
    | IDENTIFIER COLON type_id {
        $$ = mk(N_VAR_DECL);
        $$->sval = $1;
        $$->c1 = mk(N_NOP); $$->c1->sval = $3;
        $$->c2 = NULL;
    }
    | IDENTIFIER COLON type_id ASSIGN expr {
        $$ = mk(N_VAR_DECL);
        $$->sval = $1;
        $$->c1 = mk(N_NOP); $$->c1->sval = $3;
        $$->c2 = $5;
    }
    ;

type_id
    : TYPE_INT    { $$ = strdup("int"); }
    | TYPE_STRING { $$ = strdup("string"); }
    | IDENTIFIER  { $$ = $1; }
    ;

%%

void yyerror(const char *s) {
    fprintf(stderr, "Error at line %d: %s\n", yylineno, s);
}

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <input.tgr>\n", argv[0]);
        return 1;
    }
    yyin = fopen(argv[1], "r");
    if (!yyin) { perror(argv[1]); return 1; }

    int result = yyparse();
    fclose(yyin);

    if (result != 0 || !ast_root) return 1;

    char *final = gen(ast_root);
    free(final);

    sym_print();
    print_tac_raw();

    build_blocks();
    local_optimize();

    regalloc_run();
    print_reg_alloc();
    liveness_print();
    print_tac_allocated();

    return 0;
}
