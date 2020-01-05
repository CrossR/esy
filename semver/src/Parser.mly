%token <string> NUM
%token <string> WORD
%token <string> X
%token <string> V
%token DOT
%token PLUS
%token MINUS
%token OR
%token AND
%token DASH
%token STAR
%token TILDA
%token CARET
%token LT LTE GT GTE EQ
%token EOF

%start parse_version parse_formula
%type <Import.Types.Version.t> parse_version
%type <Import.Types.Formula.t> parse_formula

%{
  open Import.Types.Version
  open Import.Types.Formula
%}

%%

parse_version:
  v = version; EOF { v }

parse_formula:
  v = disj; EOF { v }

disj:
    v = range { [v] }
  | { [Simple [Patt (Pattern Any)]] }
  | v = range; OR; vs = disj { v::vs }

range:
    v = separated_nonempty_list(AND, clause) { Simple v }
  | a = pattern; DASH; b = pattern { Hyphen (a, b) }

clause:
    v = pattern { Patt v }
  | EQ;    v = pattern { Expr (EQ, v) }
  | LT;    v = pattern { Expr (LT, v) }
  | GT;    v = pattern { Expr (GT, v) }
  | LTE;   v = pattern { Expr (LTE, v) }
  | GTE;   v = pattern { Expr (GTE, v) }
  | TILDA; v = pattern { Spec (Tilda, v) }
  | CARET; v = pattern { Spec (Caret, v) }

pattern:
    v = version { Version v }
  | star { Pattern Any }
  | ioption(V); major = num; DOT; minor = num {
      Pattern (Minor (major, minor))
    }
  | ioption(V); major = num; DOT; minor = num; DOT; star {
      Pattern (Minor (major, minor))
    }
  | ioption(V); major = num {
      Pattern (Major major)
    }
  | ioption(V); major = num; DOT; star { Pattern (Major major) }
  | ioption(V); major = num; DOT; star; DOT; star {
      Pattern (Major major)
    }

star:
    STAR { () }
  | X { () }

version:
  v = version_exact; p = loption(prerelease); b = loption(build) {
    let major, minor, patch = v in
    {major; minor; patch; prerelease = p; build = b}
  }

version_exact:
  ioption(V); major = num; DOT; minor = num; DOT; patch = num {
    major, minor, patch
  }

build:
  v = preceded(PLUS, separated_nonempty_list(DOT, word)) { v }

prerelease:
  v = preceded(MINUS, separated_nonempty_list(DOT, prerelease_id)) { v }

prerelease_id:
    v = num { N v }
  | v = word { A v }

num:
  v = NUM { int_of_string v }

word:
    v = al { v }
  | v = alnum; vs = alnums { v ^ vs }

al:
    MINUS { "-" }
  | v = V { v }
  | v = X { v }
  | v = WORD { v }

alnum:
    v = al { v }
  | v = NUM { v }

alnums:
    v = alnum { v }
  | v = alnum; vs = alnums { v ^ vs }

%%
