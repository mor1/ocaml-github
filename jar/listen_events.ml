(*
 * Copyright (c) 2015 David Sheets <sheets@alum.mit.edu>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

open Lwt
open Cmdliner
open Printf

let string_of_wiki_page_action = function
  | `Created -> "Created"
  | `Edited -> "Edited"

let string_of_issue user repo issue = Github_t.(
  sprintf "%s/%s#%d (%s)" user repo issue.issue_number issue.issue_title
)

let string_of_issues_action = Github_j.string_of_issues_action

let string_of_pull user repo number = sprintf "%s/%s#%d" user repo number

let string_of_pull_request_action = Github_j.string_of_pull_request_action

let string_of_status_state = Github_j.string_of_status_state

let print_event event =
  let open Github_t in
  let user, repo =
    match Stringext.split ~max:2 ~on:'/' event.event_repo.repo_name with
    | user::repo::_ -> user, repo
    | [_] | [] -> failwith "nonsense repo name"
  in
  printf "#%Ld--> %s:" event.event_id event.event_actor.user_login;
  (match event.event_payload with
  | `CommitComment { commit_comment_event_comment = comment } ->
    printf "CommitComment on %s/%s %s\n%!"
      user repo comment.commit_comment_commit_id
  | `Create { create_event_ref = `Repository } ->
    printf "CreateEvent on repository %s/%s\n%!" user repo
  | `Create { create_event_ref = `Branch branch } ->
    printf "CreateEvent on branch %s/%s %s\n%!" user repo branch
  | `Create { create_event_ref = `Tag tag } ->
    printf "CreateEvent on tag %s/%s %s\n%!" user repo tag
  | `Delete { delete_event_ref = `Repository } ->
    printf "DeleteEvent on repository %s/%s\n%!" user repo
  | `Delete { delete_event_ref = `Branch branch } ->
    printf "DeleteEvent on branch %s/%s %s\n%!" user repo branch
  | `Delete { delete_event_ref = `Tag tag } ->
    printf "DeleteEvent on tag %s/%s %s\n%!" user repo tag
  | `Download -> printf "DownloadEvent deprecated\n%!"
  | `Follow -> printf "FollowEvent deprecated\n%!"
  | `Fork { fork_event_forkee = { repository_full_name } } ->
    printf "ForkEvent on %s/%s to %s\n%!" user repo repository_full_name
  | `ForkApply -> printf "ForkApplyEvent deprecated\n%!"
  | `Gist -> printf "GistEvent deprecated\n%!"
  | `Gollum { gollum_event_pages } ->
    printf "GollumEvent on %s/%s: %s\n%!" user repo
      (String.concat ", " (List.map (fun { wiki_page_title; wiki_page_action } ->
        (string_of_wiki_page_action wiki_page_action)^" "^wiki_page_title
       ) gollum_event_pages))
  | `IssueComment {
    issue_comment_event_action = `Created;
    issue_comment_event_issue = issue;
    issue_comment_event_comment = comment;
  } ->
    printf "IssueCommentEvent on %s: %s\n%!"
      (string_of_issue user repo issue) comment.issue_comment_body
  | `Issues { issues_event_action = action; issues_event_issue = issue } ->
    printf "IssuesEvent on %s: %s\n%!"
      (string_of_issue user repo issue) (string_of_issues_action action)
  | `Member { member_event_action = `Added; member_event_member = member } ->
    printf "MemberEvent on %s/%s: %s added\n%!"
      user repo member.linked_user_login
  | `Public ->
    printf "PublicEvent on %s/%s\n%!" user repo
  | `PullRequest {
    pull_request_event_action = action;
    pull_request_event_number;
  } ->
    printf "PullRequestEvent on %s: %s\n%!"
      (string_of_pull user repo pull_request_event_number)
      (string_of_pull_request_action action)
  | `PullRequestReviewComment {
    pull_request_review_comment_event_action = `Created;
    pull_request_review_comment_event_pull_request = pull;
    pull_request_review_comment_event_comment = comment;
  } ->
    printf "PullRequestReviewCommentEvent on %s: %s\n%!"
      (string_of_pull user repo pull.pull_number)
      comment.pull_request_review_comment_body
  | `Push { push_event_ref; push_event_size } ->
    printf "PushEvent on %s/%s ref %s of %d commits\n%!"
      user repo push_event_ref push_event_size
  | `Release { release_event_action = `Published; release_event_release } ->
    printf "ReleaseEvent on %s/%s: %s\n%!" user repo
      release_event_release.release_tag_name
  | `Status { status_event_state; status_event_sha } ->
    printf "StatusEvent on %s/%s: %s %s\n%!" user repo status_event_sha
      (string_of_status_state status_event_state)
  | `Watch { watch_event_action = `Started } ->
    printf "WatchEvent on %s/%s\n%!" user repo
  );
  return ()

let listen ~token user repo s () =
  Lwt_io.printf "listening for events on %s/%s\n" user repo
  >>= fun () ->
  let rec loop s = Github.(Monad.(
    Stream.poll s
    >>= fun stream_opt ->
    API.get_rate_remaining ~token ()
    >>= fun remaining ->
    let now = Unix.gettimeofday () in
    match stream_opt with
    | None ->
      embed
        (Lwt_io.printf "%f no new events on %s/%s (%d)\n"
           now user repo remaining
        )
      >>= fun () -> loop s
    | Some s ->
      embed
        (Lwt_io.printf "%f new events on %s/%s (%d)\n"
           now user repo remaining
        )
      >>= fun () -> loop s
  )) in
  Github.Monad.run (loop s)

let listen_events token repos =
  let repos = List.map (fun r ->
    match Stringext.split ~max:2 ~on:'/' r with
    | [user;repo] -> (user,repo)
    | _ -> eprintf "Repositories must be in username/repo format"; exit 1
  ) repos in
  (* Get the events per repo *)
  lwt _events = Lwt_list.iter_s (fun (user,repo) -> Github.(Monad.(run (
    let events = Event.for_repo ~token ~user ~repo () in
    Stream.next events
    >|= function
    | Some (_,s) -> async (listen ~token user repo s)
    | None -> assert false
  )))) repos in
  let forever, _wakener = Lwt.wait () in
  forever

let cmd =
  let cookie = Jar_cli.cookie () in
  let repos = Jar_cli.repos ~doc_append:" to query for events" () in
  let doc = "listen to events on GitHub repositories" in
  let man = [
    `S "BUGS";
    `P "Email bug reports to <mirageos-devel@lists.xenproject.org>.";
  ] in
  Term.((pure (fun t r -> Lwt_main.run (listen_events t r)) $ cookie $ repos)),
  Term.info "git-listen-events" ~version:Jar_version.t ~doc ~man

let () = match Term.eval cmd with `Error _ -> exit 1 | _ -> exit 0
