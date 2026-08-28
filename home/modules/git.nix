{ ... }:

{
  programs.git = {
    enable = true;

    # Identity is intentionally host/user-specific and is not invented here.
    # Keep it writable while the generated XDG Git config remains declarative.
    includes = [
      { path = "~/.config/git/identity"; }
    ];

    settings = {
      core = {
        editor = "vim";
        ignorecase = false;
      };

      push.default = "simple";

      color = {
        status = "auto";
        diff = "auto";
        branch = "auto";
        interactive = "auto";
        grep = "auto";
        ui = "auto";
      };

      alias = {
        a = "!git status --short | fzf --multi --exit-0 | awk '{print $2}' | xargs -r git add";
        d = "diff";
        co = "checkout";
        ci = "commit";
        ca = "commit -a";
        ps = "!git push origin $(git rev-parse --abbrev-ref HEAD)";
        pl = "!git pull origin $(git rev-parse --abbrev-ref HEAD)";
        st = "status";
        br = "branch";
        ba = "branch -a";
        bm = "branch --merged";
        bn = "branch --no-merged";
        df = "!git hist | fzf --no-sort --tac | awk '{print $2}' | xargs -r -I {} git diff {}^ {}";
        hist = "log --pretty=format:\"%Cgreen%h %Creset%cd %Cblue[%cn] %Creset%s%C(yellow)%d%C(reset)\" --graph --date=relative --decorate --all";
        llog = "log --graph --name-status --pretty=format:\"%C(red)%h %C(reset)(%cd) %C(green)%an %Creset%s %C(yellow)%d%Creset\" --date=relative";
        open = "!gh repo view --web";
        type = "cat-file -t";
        dump = "cat-file -p";
        find = "!f() { git log --pretty=format:\"%h %cd [%cn] %s%d\" --date=relative -S'pretty' -S\"$@\" | fzf --no-sort --tac | awk '{print $1}' | xargs -r -I {} git diff {}^ {}; }; f";
        edit-unmerged = "!f() { git ls-files --unmerged | cut -f2 | sort -u | xargs -r vim; }; f";
        add-unmerged = "!f() { git ls-files --unmerged | cut -f2 | sort -u | xargs -r git add; }; f";
      };

      diff.tool = "nvimdiff";
    };
  };

  xdg.configFile."git/ignore".source = ../../config/git/ignore;
}
