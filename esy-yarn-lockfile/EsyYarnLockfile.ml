(**
 * A parser of a subset of lockfile syntax enough to parse .esyrc.
 *)

include Types
include Printer

let indentSize = 2

let tokenize v =
  let lexbuf = Lexing.from_string v in

  let rec indent till curIndent indents tokens =
    if till > 0
    then indent (till - indentSize) (curIndent + indentSize) (curIndent::indents) (INDENT::tokens) 
    else curIndent, indents, tokens
  in

  let rec dedent tokens till indents =
    match indents with
    | [] -> 0, [], tokens
    | indent::indents ->
      if indent <= till then indent, indents, tokens
      else dedent (DEDENT::tokens) till indents
  in

  let rec loop (curIndent, indents) tokens =
    match Lexer.read lexbuf with
    | EOF ->
      let _, _, tokens = dedent tokens 0 (curIndent::indents) in
      List.rev (EOF::tokens)
    | NEWLINE nextIndent as token ->
      let curIndent, indents, tokens =
        if nextIndent > curIndent
        then indent (nextIndent - curIndent) curIndent indents tokens
        else if nextIndent < curIndent
        then
          let curIndent, indents, tokens = dedent tokens nextIndent (curIndent::indents) in
          curIndent, indents, token::tokens
        else curIndent, indents, token::tokens
      in
      loop (curIndent, indents) tokens
    | token ->
      loop (curIndent, indents) (token::tokens)
  in
  loop (0, []) []

let parse src =
  let open Result.Syntax in
  let src = String.trim src in
  let rtokens = ref (tokenize src) in
  let getToken _lexbuf =
    match !rtokens with
    | token::tokens ->
      rtokens := tokens;
      token
    | [] -> Types.EOF
  in
  let lexbuf = Lexing.from_string src in
  try
    return (Parser.start getToken lexbuf)
  with
  | Failure v ->
    error v
  | Parser.Error ->
    error "Syntax error"
  | Types.SyntaxError msg ->
    error msg

let parseExn src =
  match parse src with
  | Ok v -> v
  | Error err -> raise (SyntaxError err)

type 'a decoder = t -> ('a, string) result
type 'a scalarDecoder = scalar -> ('a, string) result

module Decode = struct

  let string = function
    | String v -> Ok v
    | _ -> Error "expected string"

  let number = function
    | Number v -> Ok v
    | _ -> Error "expected number"

  let boolean = function
    | Boolean v -> Ok v
    | _ -> Error "expected true or false"

  let scalar decode = function
    | Scalar scalar -> decode scalar
    | _ -> Error "expected scalar value"

  let seq decode = function
    | Sequence items ->
      let f items v =
        match decode v with
        | Ok v -> Ok (v::items)
        | Error err -> Error err
      in
      Result.List.foldLeft ~f ~init:[] items
    | _ -> Error "expected sequence"

  type fields = t StringMap.t
  type 'a fieldDecoder = fields -> ('a, string) result

  let mapping = function
    | Mapping fields ->
      let f fields (name, value) = StringMap.add name value fields in
      let fields = List.fold_left ~f ~init:StringMap.empty fields in
      Ok fields
    | _ -> Error "expected mapping"

  let field name decode fields =
    match StringMap.find_opt name fields with
    | None -> Result.errorf "no such field '%s' found" name
    | Some (value : t) -> decode value

  let fieldOpt name decode fields =
    match StringMap.find_opt name fields with
    | None -> Ok None
    | Some value ->
      begin match decode value with
      | Ok v -> Ok (Some v)
      | Error err -> Error err
      end

end

type 'a encoder = 'a -> t
type 'a scalarEncoder = 'a -> scalar

module Encode = struct

  let string v = String v
  let number v = Number v
  let boolean v = Boolean v


  let scalar encode v = Scalar (encode v)
  let seq encode vs = Sequence (List.map ~f:encode vs)

  type field = (string * t) option

  let mapping fields = Mapping (List.filterNone fields)
  let field name encode v = Some (name, encode v)
  let fieldOpt name encode v =
    match v with
    | None -> None
    | Some v -> Some (name, encode v)
end

let%test_module "tokenizing" = (module struct

  let printTokens string =
    let tokens = tokenize (String.trim string) in
    let tokens = List.map ~f:Types.sexp_of_token tokens in
    Format.printf "%a@." (Fmt.list ~sep:(Fmt.unit "@.") Sexplib0.Sexp.pp) tokens

  let%expect_test _ =
    printTokens {|a: "b"|};
    [%expect {|
      (IDENTIFIER a)
      COLON
      (STRING b)
      EOF |}]

  let%expect_test _ =
    printTokens {|
      a: "b"
    |};
    [%expect {|
      (IDENTIFIER a)
      COLON
      (STRING b)
      EOF |}]

  let%expect_test _ =
    printTokens {|
      a:
        b: "x"
          c: "y"
        c: "y"
    |};
    [%expect {|
      (IDENTIFIER a)
      COLON
      INDENT
      (IDENTIFIER b)
      COLON
      (STRING x)
      INDENT
      (IDENTIFIER c)
      COLON
      (STRING y)
      DEDENT
      (NEWLINE 9)
      (IDENTIFIER c)
      COLON
      (STRING y)
      DEDENT
      EOF |}]

  let%expect_test _ =
    printTokens {|
      a:
        b: "x"
      c: "y"
    |};
    [%expect {|
      (IDENTIFIER a)
      COLON
      INDENT
      (IDENTIFIER b)
      COLON
      (STRING x)
      DEDENT
      (NEWLINE 7)
      (IDENTIFIER c)
      COLON
      (STRING y)
      EOF |}]

  let%expect_test _ =
    printTokens {|
a: b
c: d
    |};
    [%expect {|
      (IDENTIFIER a)
      COLON
      (IDENTIFIER b)
      (NEWLINE 0)
      (IDENTIFIER c)
      COLON
      (IDENTIFIER d)
      EOF |}]

  let%expect_test _ =
    printTokens {|
a:
  c: d
    |};
    [%expect {|
      (IDENTIFIER a)
      COLON
      INDENT
      (IDENTIFIER c)
      COLON
      (IDENTIFIER d)
      DEDENT
      EOF |}]

  let%expect_test _ =
    printTokens {|
a:
  c: d
  e: f
    |};
    [%expect {|
      (IDENTIFIER a)
      COLON
      INDENT
      (IDENTIFIER c)
      COLON
      (IDENTIFIER d)
      DEDENT
      EOF |}]

  let%expect_test _ =
    printTokens {|
a:
  c: d
    |};
    [%expect {|
      (IDENTIFIER a)
      COLON
      INDENT
      (IDENTIFIER c)
      COLON
      (IDENTIFIER d)
      DEDENT
      EOF |}]

  let%expect_test _ =
    printTokens {|
a:
  c: d
e: f
    |};
    [%expect {|
      (IDENTIFIER a)
      COLON
      INDENT
      (IDENTIFIER c)
      COLON
      (IDENTIFIER d)
      DEDENT
      (NEWLINE 0)
      (IDENTIFIER e)
      COLON
      (IDENTIFIER f)
      EOF |}]

  let%expect_test _ =
    printTokens {|
a:
  - a: 1
  - b: 2
    |};
    [%expect {|
      (IDENTIFIER a)
      COLON
      INDENT
      LI
      (IDENTIFIER a)
      COLON
      (NUMBER 1)
      (NEWLINE 3)
      LI
      (IDENTIFIER b)
      COLON
      (NUMBER 2)
      DEDENT
      EOF |}]

  let%expect_test _ =
    printTokens {|
a:
  - a: 1
    b: 2
    |};
    [%expect {|
      (IDENTIFIER a)
      COLON
      INDENT
      LI
      (IDENTIFIER a)
      COLON
      (NUMBER 1)
      INDENT
      (IDENTIFIER b)
      COLON
      (NUMBER 2)
      DEDENT
      DEDENT
      EOF |}]

end)

let%test_module _ = (module struct

  let printTokens string =
    let tokens = tokenize (String.trim string) in
    let tokens = List.map ~f:Types.sexp_of_token tokens in
    Format.printf "%a@." (Fmt.list ~sep:(Fmt.unit "@.") Sexplib0.Sexp.pp) tokens

  let printAst s =
    match parse s with
    | Ok s -> Format.printf "%a@." Sexplib0.Sexp.pp_hum (sexp_of_t s)
    | Error err -> Format.printf "ERROR: %s@." err

  let%expect_test "empty" =
    printAst "";
    [%expect {| (Mapping ()) |}]

  let%expect_test "empty with newline" =
    printAst "\n";
    [%expect {| (Mapping ()) |}]

  let%expect_test "id:true" =
    printAst "id:true";
    [%expect {| (Mapping ((id (Scalar (Boolean true))))) |}]

  let%expect_test "id: true" =
    printAst "id: true";
    [%expect {| (Mapping ((id (Scalar (Boolean true))))) |}]

  let%expect_test "id :true" =
    printAst "id :true";
    [%expect {| (Mapping ((id (Scalar (Boolean true))))) |}]

  let%expect_test " id:true" =
    printAst " id:true";
    [%expect {| (Mapping ((id (Scalar (Boolean true))))) |}]

  let%expect_test "id:true " =
    printAst "id:true ";
    [%expect {| (Mapping ((id (Scalar (Boolean true))))) |}]

  let%expect_test "id: false" =
    printAst "id: false";
    [%expect {| (Mapping ((id (Scalar (Boolean false))))) |}]

  let%expect_test "id: id" =
    printAst "id: id";
    [%expect {| (Mapping ((id (Scalar (String id))))) |}]

  let%expect_test "id: string" =
    printAst {|id: "string"|};
    [%expect {| (Mapping ((id (Scalar (String string))))) |}]

  let%expect_test "id: 1" =
    printAst "id: 1";
    [%expect {| (Mapping ((id (Scalar (Number 1))))) |}]

  let%expect_test "id: 1.5" =
    printAst "id: 1.5";
    [%expect {| (Mapping ((id (Scalar (Number 1.5))))) |}]

  let%expect_test "\"string\": ok" =
    printAst "\"string\": ok";
    [%expect {| (Mapping ((string (Scalar (String ok))))) |}]

  let%expect_test "a:b\nc:d" =
    printAst "a:b\nc:d";
    [%expect {| (Mapping ((a (Scalar (String b))) (c (Scalar (String d))))) |}]

  let%expect_test "a:b\n" =
    printAst "a:b\n";
    [%expect {| (Mapping ((a (Scalar (String b))))) |}]

  let%expect_test "\na:b" =
    printAst "\na:b";
    [%expect {| (Mapping ((a (Scalar (String b))))) |}]

  let%expect_test "esy-store-path: \"/some/path\"" =
    printAst "esy-store-path: \"/some/path\"";
    [%expect {| (Mapping ((esy-store-path (Scalar (String /some/path))))) |}]

  let%expect_test "esy-store-path: \"./some/path\"" =
    printAst "esy-store-path: \"./some/path\"";
    [%expect {| (Mapping ((esy-store-path (Scalar (String ./some/path))))) |}]

  let%expect_test "esy-store-path: ./some/path" =
    printAst "esy-store-path: ./some/path";
    [%expect {| (Mapping ((esy-store-path (Scalar (String ./some/path))))) |}]

  let%expect_test _ =
    printAst {|
      a: b
    |};
    [%expect {| (Mapping ((a (Scalar (String b))))) |}]

  let%expect_test _ =
    printAst {|
a: b
c: d
    |};
    [%expect {| (Mapping ((a (Scalar (String b))) (c (Scalar (String d))))) |}]

  let%expect_test _ =
    printAst {|
a:
  c: d
    |};
    [%expect {| (Mapping ((a (Mapping ((c (Scalar (String d)))))))) |}]

  let%expect_test _ =
    printTokens {|
a:
  c: d
  e: f
    |};
    printAst {|
a:
  c: d
  e: f
    |};
    [%expect {| (Mapping ((a (Mapping ((c (Scalar (String d))) (e (Scalar (String f)))))))) |}]

  (* let%expect_test _ = *)
  (*   printAst {| *)
(* a: *)
  (* c: d *)
(* e: f *)
  (*   |}; *)
  (*   [%expect {| (Mapping ((a (Mapping ((c (Scalar (String d)))))) (e (Scalar (String f))))) |}] *)

  (* let%expect_test _ = *)
  (*   printAst {| *)
(* a: *)
  (* c: *)
  (*   e: f *)
  (*   |}; *)
  (*   [%expect {| (Mapping ((a (Mapping ((c (Mapping ((e (Scalar (String f))))))))))) |}] *)

  (* let%expect_test _ = *)
  (*   printAst {| *)
(* a: *)
  (* c: *)
  (*   e: *)
  (*     g: h *)
  (* x: y *)
  (*   |}; *)
  (*   [%expect {| *)
  (*     (Mapping *)
  (*      ((a *)
  (*        (Mapping *)
  (*         ((c (Mapping ((e (Mapping ((g (Scalar (String h))))))))) *)
  (*          (x (Scalar (String y)))))))) |}] *)

  (* let%expect_test _ = *)
  (*   printAst {| *)
(* a: *)
  (* c: *)
  (*   e: *)
  (*     g: h *)
(* x: y *)
  (*   |}; *)
  (*   [%expect {| *)
  (*     (Mapping *)
  (*      ((a (Mapping ((c (Mapping ((e (Mapping ((g (Scalar (String h)))))))))))) *)
  (*       (x (Scalar (String y))))) |}] *)

  (* let%expect_test _ = *)
  (*   printAst {| *)
(* a: *)
  (* - 1 *)
  (* - 2 *)
  (*   |}; *)
  (*   [%expect {| *)
  (*     (Mapping ((a (Sequence ((Number 1) (Number 2)))))) |}] *)

  (* let%expect_test _ = *)
  (*   printAst {| *)
(* a: *)
  (* - 2 *)
  (*   |}; *)
  (*   [%expect {| *)
  (*     (Mapping ((a (Sequence ((Number 2)))))) |}] *)

  (* let%expect_test _ = *)
  (*   printAst {| *)
(* a: *)
  (* - a *)
  (* - b *)
  (* - c *)
  (*   |}; *)
  (*   [%expect {| *)
  (*     (Mapping ((a (Sequence ((String a) (String b) (String c)))))) |}] *)

(* end) *)

(* let%test_module _ = (module struct *)

  (* let parsePrint s = *)
  (*   match parse s with *)
  (*   | Ok s -> Format.printf "%a@." pp s *)
  (*   | Error err -> Format.printf "ERROR: %s@." err *)

  (* let%expect_test _ = *)
  (*   parsePrint {| *)
(* a: 2 *)
  (*   |}; *)
  (*   [%expect {| a: 2 |}] *)

  (* let%expect_test _ = *)
  (*   parsePrint {| *)
(* a: 2 *)
(* c: d *)
  (*   |}; *)
  (*   [%expect {| *)
  (*     a: 2 *)
  (*     c: d |}] *)

  (* let%expect_test _ = *)
  (*   parsePrint {| *)
(* a: *)
  (* c: d *)
  (*   |}; *)
  (*   [%expect {| *)
  (*     a: *)
  (*       c: d |}] *)

  (* let%expect_test _ = *)
  (*   parsePrint {| *)
(* a: *)
  (* c: d *)
(* c: d *)
  (*   |}; *)
  (*   [%expect {| *)
  (*     a: *)
  (*       c: d *)
  (*     c: d |}] *)

  (* let%expect_test _ = *)
  (*   parsePrint {| *)
(* a: *)
  (* c: *)
  (*   c: d *)
  (*   |}; *)
  (*   [%expect {| *)
  (*     a: *)
  (*       c: *)
  (*         c: d |}] *)

  (* let%expect_test _ = *)
  (*   parsePrint {| *)
(* a: *)
  (* - 1 *)
  (* - 2 *)
  (* - 3 *)
  (*   |}; *)
  (*   [%expect {| *)
  (*     a: *)
  (*       - 1 *)
  (*       - 2 *)
  (*       - 3 |}] *)

  (* let%expect_test _ = *)
  (*   parsePrint {| *)
(* "key with space": "value with space" *)
  (*   |}; *)
  (*   [%expect {| *)
  (*     "key with space": "value with space" |}] *)

end)
