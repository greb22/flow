(**
 * Copyright (c) 2013-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "flow" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

open Utils_js

(* sketch of baseline incremental alg:

   Note: this is for strict mode only, which is the easy case,
   since it doesn't require a transitive merge of all modules
   connected via nonlocal type flows.

   Total case over set of modules M:
    1. for all m:M, do local inference on m, producing graph m.g
    2. for all m:M, for all r:m.required,
      perform substitution of r.export into m.g, producing m.g'

   Incremental case, given previously established modules m:
    1. Mt = (touched) reparse of all m:M where m.file has been updated
    2. for all m:Mt do local inference on m, producing m.g
    3. Mx = (export) m:Mt where m.export or m.name have changed
    4. Md = m:M where m.file has been deleted
    5. Mr = (recheck) m:Mt | (M where !empty(m.required & (Mx | Md))
      (all touched modules plus all others whose required sets
       include any export changes or deletions)
    5. for all m:Mr, for all r:m.required,
        perform substitution of r.export into m.g, producing m.g'
*)

(* produce, given files in fileset:
   (1) a map from those files to modules
   (2) a reverse dependency map for those files:
       the key is the module provided by a file;
       the value is the subset of files which require that module directly
   (3) a subset of those files that phantom depend on root_fileset
 *)
let calc_dep_utils workers fileset root_fileset = Module_js.(
  (* Distribute work, looking up InfoHeap and ResolvedRequiresHeap once per file. *)
  let job = List.fold_left (fun (modules, rdmap, resolution_path_files) f ->
    let resolved_requires = get_resolved_requires_unsafe ~audit:Expensive.ok f in
    let info = get_info_unsafe ~audit:Expensive.ok f in
    (* Add f |-> info._module to the `modules` map. This will be used downstream
       in dep_closure.

       TODO: Why do we this here rather than there? This used to be an
       optimization, since InfoHeap and ResolvedRequiresHeap were
       together. Will clean up later.

       TODO: explore whether we can avoid creating this map on every recheck,
       instead maintaining the map incrementally and hopefully reusing large
       parts of it.
    *)
    let modules = FilenameMap.add f info._module modules in
    (* For every r in resolved_requires.required, add f to the reverse dependency list for r,
       stored in `rdmap`. This will be used downstream when computing
       direct_deps, and also in dep_closure.

       TODO: should generate this map once on startup, keep required_by in
       module records and update incrementally on recheck.
    *)

    let rdmap = NameSet.fold (fun r rdmap ->
      NameMap.add r FilenameSet.(
        match NameMap.get r rdmap with
        | None -> singleton f
        | Some files -> add f files
      ) rdmap
    ) resolved_requires.required rdmap in
    (* If f's phantom dependents are in root_fileset, then add f to
       `resolution_path_files`. These are considered direct dependencies (in
       addition to others computed by direct_deps downstream). *)
    let resolution_path_files =
      if resolved_requires.phantom_dependents |> SSet.exists (fun f ->
        FilenameSet.mem (Loc.SourceFile f) root_fileset ||
        FilenameSet.mem (Loc.JsonFile f) root_fileset ||
        FilenameSet.mem (Loc.ResourceFile f) root_fileset
      ) then FilenameSet.add f resolution_path_files
      else resolution_path_files in
    modules, rdmap, resolution_path_files
  ) in
  (* merge results *)
  let merge
      (modules1, rdmap1, resolution_path_files1)
      (modules2, rdmap2, resolution_path_files2) =
    FilenameMap.union modules1 modules2,
    NameMap.merge (fun _ x y ->
      match x, y with
      | Some v, None
      | None, Some v -> Some v
      | Some v, Some w -> Some (FilenameSet.union v w)
      | None, None -> None
    ) rdmap1 rdmap2,
    FilenameSet.union resolution_path_files1 resolution_path_files2
  in

  MultiWorker.call workers ~job ~merge
    ~neutral: Module_js.(FilenameMap.empty, NameMap.empty, FilenameSet.empty)
    ~next: (MultiWorker.next workers (FilenameSet.elements fileset))
)

(* given a reverse dependency map (from modules to the files which
   require them), generate the closure of the dependencies of a
   given fileset, using get_info_unsafe to map files to modules
 *)
let dep_closure modules rdmap fileset =
  let deps_of_module m = Module_js.NameMap.get m rdmap in
  let deps_of_file f =
    let m = FilenameMap.find_unsafe f modules in
    let f_module = Modulename.Filename f in
    (* In general, a file exports its module via two names. See Modulename for
       details. It suffices to note here that dependents of the file can use
       either of those names to import the module. *)
    match deps_of_module m, deps_of_module f_module with
      | None, None -> FilenameSet.empty
      | None, Some deps
      | Some deps, None -> deps
      | Some deps1, Some deps2 -> FilenameSet.union deps1 deps2
  in
  let rec expand rdmap fileset seen =
    FilenameSet.fold (fun f acc ->
      if FilenameSet.mem f !seen then acc else (
        seen := FilenameSet.add f !seen;
        let deps = deps_of_file f in
        FilenameSet.add f (FilenameSet.union acc (expand rdmap deps seen))
      )
    ) fileset FilenameSet.empty
  in expand rdmap fileset (ref FilenameSet.empty)

(* Files that must be rechecked include those that immediately or recursively
   depended on modules whose providers were affected by new, changed, or deleted
   files.

   Providers are affected only in those cases already considered by
   commit_modules: as such, the arguments to dependent_files are similar to
   those of commit_modules.

   Identify the direct and transitive dependents of new or changed files and
   cleared modules.

   - unchanged_parsed is all unchanged files in the current state
   - new_or_changed is all files that have just been through local inference and
     all skipped files that were also new or unchanged
   - cleared_modules is all modules whose records have just been cleared.

   Note that while cleared_modules and (the modules provided by) new_or_changed
   usually overlap, new_or_changed will include providers of new modules, and
   cleared_modules will include modules provided by deleted files.

   Return the subset of unchanged_parsed transitively dependent on updates, and
   the subset directly dependent on them.
*)
let dependent_files workers ~unchanged_parsed ~new_or_changed ~cleared_modules =
  (* Get the modules provided by unchanged files, the reverse dependency map
     for unchanged files, and the subset of unchanged files whose resolution
     paths may encounter new or changed modules. *)
  (** [shared mem access] InfoHeap.get and ResolvedRequiresHeap.get on unchanged_files for
      ._module, .required, .phantom_dependents **)
  let modules,
    reverse_deps,
    resolution_path_files
    = calc_dep_utils workers unchanged_parsed new_or_changed in

  (* touched_modules includes cleared modules and those provided by new files *)
  (** [shared mem access] InfoHeap.get on new_or_changed for ._module **)
  let touched_modules = Module_js.(NameSet.union cleared_modules (
    MultiWorker.call workers
      ~job: (List.fold_left (fun mods file ->
        let file_mods = get_module_names_unsafe ~audit:Expensive.ok file in
        (* Add all module names exported by file *)
        List.fold_left (fun acc m -> NameSet.add m acc) mods file_mods
      ))
      ~neutral: NameSet.empty
      ~merge: NameSet.union
      ~next: (MultiWorker.next workers (FilenameSet.elements new_or_changed))
  )) in

  (* files that require touched modules directly, or may resolve to
     modules provided by changed files *)
  let direct_deps = Module_js.(NameSet.fold (fun m acc ->
    match NameMap.get m reverse_deps with
    | Some files -> FilenameSet.union acc files
    | None -> acc
    ) touched_modules resolution_path_files
  ) in

  (* (transitive dependents are re-merged, directs are also re-resolved) *)
  dep_closure modules reverse_deps direct_deps,
  direct_deps


(* Calculate module dependencies. Since this involves a lot of reading from
   shared memory, it is useful to parallelize this process (leading to big
   savings in init and recheck times). *)


let checked ~audit m = Module_js.(
  let info = m |> get_file_unsafe ~audit |> get_info_unsafe ~audit in
  info.checked
)

(* A file is considered to implement a required module r only if the file is
   registered to provide r and the file is checked. Such a file must be merged
   before any file that requires module r, so this notion naturally gives rise
   to a dependency ordering among files for merging. *)
let implementation_file ~audit r = Module_js.(
  if module_exists r && checked ~audit r
  then Some (get_file_unsafe ~audit r)
  else None
)

let calc_dependencies workers files =
  let deps = MultiWorker.call
    workers
    ~job: (List.fold_left (fun deps file ->
      let { Module_js.required; _ } =
        Module_js.get_resolved_requires_unsafe ~audit:Expensive.ok file in
      let files = Module_js.NameSet.fold (fun r files ->
        match implementation_file ~audit:Expensive.ok r with
        | Some f -> FilenameSet.add f files
        | None -> files
      ) required FilenameSet.empty in
      FilenameMap.add file files deps
    ))
    ~neutral: FilenameMap.empty
    ~merge: FilenameMap.union
    ~next: (MultiWorker.next workers files) in
  deps |> FilenameMap.map (
    FilenameSet.filter (fun f -> FilenameMap.mem f deps))
