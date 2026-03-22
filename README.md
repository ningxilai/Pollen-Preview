# 依赖

该包依赖于 [deno-bridge](https://github.com/manateelazycat/deno-bridge) 与 [EmacsWebsocket](https://github.com/ahyatt/emacs-websocket)，在使用前应当安装 Deno、Pandoc 与 Racket Pollen，如需其他后端，也应自行安装。

## 安装

``` lisp
(setup (:elpaca websocket))

(setup (:elpaca deno-bridge :host github :repo "manateelazycat/deno-bridge"))

(setup (:elpaca pandoc-preview :host github :repo "ningxilai/PandocPreview" :files (:defaults "pandoc-preview.el" "pandoc-preview.ts" (:exclude "README.md"))))
```

# 扩展

如上文所述，该包的扩展非常简单，仅需要修改 `pandoc-preview-backends`。
