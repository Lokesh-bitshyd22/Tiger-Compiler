%option yylineno
%option noyywrap

%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include "tiger_parser.tab.h"

char strbuf[4096];
int str_index = 0;

void reset_string(){ str_index = 0; }
void add_char(char c) { if (str_index < 4095) strbuf[str_index++] = c; }
void finish_string(){ strbuf[str_index] = '\0'; }

void lex_error(const char *msg){
    fprintf(stderr, "Lexical Error at line %d: %s\n", yylineno, msg);
}
%}

%x STRING
%x COMMENT

IDENTIFIER [A-Za-z][A-Za-z0-9_]*
INTEGER    [0-9]+
WS         [ \t\r]+

%%

"/*"                  { BEGIN(COMMENT); }
<COMMENT>"*/"         { BEGIN(INITIAL); }
<COMMENT>\n           {}
<COMMENT>.            {}
<COMMENT><<EOF>>      { lex_error("Unterminated comment"); BEGIN(INITIAL); }



"array"   { return ARRAY; }
"break"   { return BREAK; }
"do"      { return DO; }
"else"    { return ELSE; }
"end"     { return END; }
"if"      { return IF; }
"in"      { return IN; }
"let"     { return LET; }
"nil"     { return NIL; }
"of"      { return OF; }
"then"    { return THEN; }
"type"    { return TYPE; }
"var"     { return VAR; }
"while"   { return WHILE; }
"int"     { return TYPE_INT; }
"string"  { return TYPE_STRING; }

":="  { return ASSIGN; }
"<>"  { return NEQ; }
"<="  { return LE; }
">="  { return GE; }
"<"   { return LT; }
">"   { return GT; }
"="   { return EQ; }
"+"   { return PLUS; }
"-"   { return MINUS; }
"*"   { return TIMES; }
"/"   { return DIVIDE; }
"&"   { return AND; }
"|"   { return OR; }

"("   { return LPAREN; }
")"   { return RPAREN; }
"["   { return LBRACKET; }
"]"   { return RBRACKET; }
":"   { return COLON; }
";"   { return SEMICOLON; }

\"                    { BEGIN(STRING); reset_string(); }
<STRING>[^\\\"\n]+    { for (int i = 0; i < yyleng; i++) add_char(yytext[i]); }
<STRING>\\n           { add_char('\n'); }
<STRING>\\t           { add_char('\t'); }
<STRING>\\\"          { add_char('\"'); }
<STRING>\\\\          { add_char('\\'); }
<STRING>\\\^[A-Z@\[\]\\\^_] { add_char(yytext[2] & 0x1F); }
<STRING>\\[ \t\n]+\\  {}
<STRING>\\.           { lex_error("Invalid escape sequence"); }
<STRING>\"            { finish_string(); yylval.sval = strdup(strbuf); BEGIN(INITIAL); return STRING_LITERAL; }
<STRING>\n            { lex_error("Unterminated string"); BEGIN(INITIAL); }
<STRING><<EOF>>       { lex_error("EOF inside string"); BEGIN(INITIAL); }

{INTEGER} {
    long val = strtol(yytext, NULL, 10);
    if (val > INT_MAX) {
        fprintf(stderr, "ERROR: Integer overflow at line %d\n", yylineno);
        val = INT_MAX;
    }
    yylval.ival = (int)val;
    return INTEGER_LITERAL;
}

{IDENTIFIER} { yylval.sval = strdup(yytext); return IDENTIFIER; }

{WS}  {}
\n    {}

. {
    fprintf(stderr, "Lexical Error at line %d: Invalid character '%s'\n", yylineno, yytext);
}

%%
