open! Import

include Types.Formula

let parse v =
  let lexbuf = Lexing.from_string v in
  match Parser.parse_formula Lexer.(make main ()) lexbuf with
  | exception Lexer.Error msg ->
    let msg = Printf.sprintf "error parsing `%s`: %s" v msg in
    Error msg
  | exception Parser.Error ->
    (* let pos = lexbuf.Lexing.lex_curr_p.pos_cnum in *)
    let msg = Printf.sprintf "error parsing `%s`: %s" v "invalid formula" in
    Error msg
  | v -> Ok v

let parse_exn v =
  match parse v with
  | Ok v -> v
  | Error msg -> failwith msg

let pp_op fmt v =
  match v with
  | GT -> Pp.pp_const ">" fmt ()
  | LT -> Pp.pp_const "<" fmt ()
  | EQ -> Pp.pp_const "" fmt ()
  | GTE -> Pp.pp_const ">=" fmt ()
  | LTE -> Pp.pp_const "<=" fmt ()

let pp_spec fmt v =
  match v with
  | Tilda -> Pp.pp_const "~" fmt ()
  | Caret -> Pp.pp_const "^" fmt ()

let pp_pattern fmt v =
  match v with
  | Major x -> Format.fprintf fmt "%i.x.x" x
  | Minor (x, y) -> Format.fprintf fmt "%i.%i.x" x y
  | Any -> Format.fprintf fmt "*"

let pp_version_or_pattern fmt v =
  match v with
  | Version v -> Version.pp fmt v
  | Pattern v -> pp_pattern fmt v

let pp_clause fmt v =
  match v with
  | Patt p -> pp_version_or_pattern fmt p
  | Spec (spec, p) ->
    Format.fprintf fmt "%a%a" pp_spec spec pp_version_or_pattern p
  | Expr (op, p) ->
    Format.fprintf fmt "%a%a" pp_op op pp_version_or_pattern p

let pp_range fmt v =
  match v with
  | Hyphen (a, b) ->
    Format.fprintf fmt
      "%a - %a"
      pp_version_or_pattern a pp_version_or_pattern b
  | Simple xs ->
    Pp.(pp_list (pp_const " ") pp_clause) fmt xs

let pp = Pp.(pp_list (pp_const " || ") pp_range)

let show v = Format.asprintf "%a" pp v

module N = struct
  type t = (op * Version.t) list list

  (* NOTE: we strip build metadata from any version per semver spec *)
  let of_formula ranges =
    let to_version = function
      | Any -> Version.make 0 0 0
      | Major major -> Version.make major 0 0
      | Minor (major, minor) -> Version.make major minor 0
    in
    let to_next_version = function
      | Any -> Version.make 0 0 0
      | Major major -> Version.make (major + 1) 0 0
      | Minor (major, minor) -> Version.make major (minor + 1) 0
    in
    let conv_hyphen a b =
      let a =
        match a with
        | Version a -> Some (GTE, Version.strip_build a)
        | Pattern Any  -> None
        | Pattern a -> Some (GTE, to_version a)
      in
      let b =
        match b with
        | Version b -> Some (LTE, Version.strip_build b)
        | Pattern Any -> None
        | Pattern b -> Some (LT, to_next_version b)
      in
      a, b
    in
    let conv_tilda v =
      match v with
      | Version v ->
        (GTE, Version.strip_build v),
        (LT, Version.next_minor v)
      | Pattern p ->
        (GTE, to_version p),
        (LT, to_next_version p)
    in
    let conv_caret v =
      match v with
      | Version ({major = 0; minor = 0; _} as v) ->
        (GTE, Version.strip_build v),
        Some (LT, Version.next_patch v)
      | Version ({major = 0; _} as v) ->
        (GTE, Version.strip_build v),
        Some (LT, Version.next_minor v)
      | Version v ->
        (GTE, Version.strip_build v),
        Some (LT, Version.next_major v)
      | Pattern Any ->
        (GTE, (to_version Any)),
        None
      | Pattern ((Major _) as p) ->
        let v = to_version p in
        (GTE, v),
        Some (LT, Version.(next_major v))
      | Pattern (Minor (0, _) as p) ->
        let v = to_version p in
        (GTE, v),
        Some (LT, Version.next_minor v)
      | Pattern (Minor _ as p) ->
        let v = to_version p in
        (GTE, v),
        Some (LT, Version.next_major v)
    in
    let conv_x_range p =
      match p with
      | Any -> (GTE, to_version p), None
      | _ -> (GTE, to_version p), Some (LT, to_next_version p)
    in
    List.map ranges ~f:(function
      | Hyphen (left, right) ->
        begin match conv_hyphen left right with
        | Some left, Some right -> [left; right]
        | Some left, None -> [left]
        | None, Some right -> [right]
        | None, None -> [GTE, Version.make 0 0 0]
        end
      | Simple xs ->
        xs
        |> List.fold_left ~init:[] ~f:(fun acc -> function
          | Expr (op, Version v) -> (op, Version.strip_build v)::acc
          | Expr (EQ, Pattern p) -> (EQ, to_version p)::acc
          | Expr (GTE, Pattern p) -> (GTE, to_version p)::acc
          | Expr (LTE, Pattern p) -> (LTE, to_version p)::acc
          | Expr (LT, Pattern p) ->
            (* ex: <* means <0.0.0, effectively matches no version *)
            (* ex: <1 means <1.0.0 *)
            (* ex: <1.2 means <1.2.0 *)
            (LT, to_version  p)::acc
          | Expr (GT, Pattern Any) ->
            (* ex: >* means <0.0.0, effectively matches no version *)
            (LT, Version.make 0 0 0)::acc
          | Expr (GT, Pattern Major a) ->
            (* ex: >1 means >=2.0.0 *)
            (GTE, Version.make (a + 1) 0 0)::acc
          | Expr (GT, Pattern Minor (a, b)) ->
            (* ex: >1.2 means >=1.3.0 *)
            (GTE, Version.make a (b + 1) 0)::acc
          | Spec (Caret, v) ->
            begin match conv_caret v with
            | left, Some right -> right::left::acc
            | left, None -> left::acc
            end
          | Spec (Tilda, v) ->
            let left, right = conv_tilda v in
            right::left::acc
          | Patt (Version v) ->
            (EQ, Version.strip_build v)::acc
          | Patt (Pattern p) ->
            begin match conv_x_range p with
            | left, Some right -> right::left::acc
            | left, None -> left::acc
            end
        )
        |> List.rev
    )

  let to_formula disj =
    List.map disj ~f:(fun conj ->
      Simple (List.map conj ~f:(fun (op, v) ->
        Expr (op, Version v))))

  let pp fmt v = pp fmt (to_formula v)
  let show v = Format.asprintf "%a" pp v

end

let normalize = N.of_formula

let satisfies f v =
  (* we don't take into account build metadata per semver *)
  let v = Version.strip_build v in
  let check_clause = function
    | EQ, e -> Version.compare v e = 0
    | LT, e -> Version.compare v e < 0
    | LTE, e -> Version.compare v e <= 0
    | GT, e -> Version.compare v e > 0
    | GTE, e -> Version.compare v e >= 0
  in
  let disj = normalize f in
  if Version.is_prerelease v then
    let v_strict = Version.strip_prerelease v in
    let check_conj conj =
      (* check for clause with prerelease with the same major, minor, patch as
       * the version *)
      let allow_prerelease_match =
        List.exists conj ~f:(fun (_op, e) ->
          Version.(is_prerelease e && equal (strip_prerelease e) v_strict))
      in
      allow_prerelease_match && List.for_all conj ~f:(fun (op, e) ->
        check_clause (op, e)
      )
    in
    List.exists disj ~f:check_conj
  else
    (* fast-path for non-prerelease versions *)
    List.(exists disj ~f:(List.for_all ~f:check_clause))


