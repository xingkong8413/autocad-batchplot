;;; ==================================================================
;;;  BatchPlot.lsp   AutoCAD 批量打印插件（批量输出 PDF）
;;;  版本: 1.00      适用: AutoCAD 2010 及以上（Windows 完整版，不支持 LT）
;;;
;;;  命令:
;;;    BP       当前图纸的所有布局 -> 每个布局输出一个 PDF
;;;    BPF      指定文件夹（可含子文件夹）内所有 DWG -> 逐个批量输出 PDF
;;;    BPSET    查看 / 修改打印设置（保存到注册表）
;;;    BPHELP   显示帮助
;;;
;;;  特性:
;;;    1. 只替换“打印设备”为 DWG To PDF.pc3 并按设置选定纸张；
;;;       打印区域、旋转、着色打印、图层等沿用各布局原有页面设置。
;;;    2. 文件名规则: 前缀 + 图纸名 + "-" + 布局名 + 后缀 + .pdf
;;;    3. 同名 PDF 自动追加序号，不覆盖已有文件。
;;;    4. 全程写日志（时间/图纸/布局/PDF/结果），便于核对。
;;;    5. 批处理前后自动关闭后台打印、恢复系统变量。
;;; ==================================================================

(vl-load-com)

(setq *bp:ver*    "1.00")
(setq *bp:dev*    "DWG To PDF.pc3")
(setq *bp:cfg*    nil)
(setq *bp:mcache* nil)
(setq *bp:logf*   nil)

;;; ------------------------------------------------------------------
;;; 一、基础工具
;;; ------------------------------------------------------------------

(defun bp:app () (vlax-get-acad-object))

(defun bp:doc () (vla-get-ActiveDocument (bp:app)))

(defun bp:trim (s)
  (vl-string-trim " \t" (if s s ""))
)

;; 统一用正斜杠，AutoCAD 文件 API 全部接受
(defun bp:fullpath (p)
  (vl-string-translate "\\" "/" (if p p ""))
)

(defun bp:strip-slash (p)
  (setq p (if p p ""))
  (while (and (> (strlen p) 3)
              (member (substr p (strlen p) 1) (list "/" "\\")))
    (setq p (substr p 1 (1- (strlen p))))
  )
  p
)

(defun bp:dirf (p) (strcat (bp:strip-slash p) "/"))

(defun bp:int-of (s) (if (= (bp:trim s) "1") 1 0))

(defun bp:say (s) (princ s))

(defun bp:split (s ch / out pos)
  (setq out nil)
  (while (setq pos (vl-string-position (ascii ch) s))
    (setq out (append out (list (substr s 1 pos))))
    (setq s (substr s (+ pos 2)))
  )
  (append out (list s))
)

(defun bp:filep (f / sz)
  (cond
    ((or (null f) (= f "")) nil)
    ((findfile f) T)
    (T
      (setq sz (vl-catch-all-apply 'vl-file-size (list f)))
      (if (or (vl-catch-all-error-p sz) (null sz)) nil T)
    )
  )
)

;; 逐级创建目录
(defun bp:mkdirs (dir / lst acc)
  (setq dir (bp:strip-slash (bp:fullpath dir)))
  (cond
    ((vl-file-directory-p dir) T)
    (T
      (setq lst (bp:split dir "/"))
      (setq acc "")
      (foreach seg lst
        (setq acc (if (= acc "") seg (strcat acc "/" seg)))
        (if (and (/= acc "") (not (vl-file-directory-p acc)))
          (vl-catch-all-apply 'vl-mkdir (list acc))
        )
      )
      (if (vl-file-directory-p dir) T nil)
    )
  )
)

;; 文件名非法字符替换
(defun bp:clean (s / i ch out bad)
  (setq bad (list "\\" "/" ":" "*" "?" (chr 34) "<" ">" "|"))
  (setq out "" i 1)
  (repeat (strlen s)
    (setq ch (substr s i 1))
    (setq out (strcat out (if (member ch bad) "_" ch)))
    (setq i (1+ i))
  )
  (if (= out "") "_" out)
)

(defun bp:stamp ()
  (menucmd "M=$(edtime,$(getvar,date),YYYY-MO-DD_HHMMSS)")
)

(defun bp:now ()
  (menucmd "M=$(edtime,$(getvar,date),YYYY-MO-DD HH:MM:SS)")
)

;;; ------------------------------------------------------------------
;;; 二、配置（注册表 HKCU\Software\Doubao\BatchPlot）
;;; ------------------------------------------------------------------

(defun bp:cfg-defaults ()
  (list
    (cons "PAPER"      "AUTO")       ; A0/A1/A2/A3/A4/LETTER，AUTO=沿用布局
    (cons "SCALE"      "LAYOUT")   ; LAYOUT=沿用布局比例，FIT=布满图纸
    (cons "STYLESHEET" "")         ; 打印样式表完整路径，空=沿用布局
    (cons "OUTDIR"     "")         ; 空=<源目录>/PDF，AUTO=源目录本身
    (cons "INCMODEL"   "1")        ; 是否包含模型空间
    (cons "SKIPEMPTY"  "1")        ; 是否跳过空布局
    (cons "SUB"        "0")        ; BPF 是否含子文件夹
    (cons "PREFIX"     "")
    (cons "SUFFIX"     "")
    (cons "OPEN"       "1")        ; 完成后打开输出目录
    (cons "ENGINE"     "COM")      ; COM=ActiveX 出图，PLOT=-PLOT 命令行出图
  )
)

(defun bp:reg-key () "HKEY_CURRENT_USER\\Software\\Doubao\\BatchPlot")

(defun bp:cfg-save ( / ok)
  (setq ok T)
  (foreach pr *bp:cfg*
    (if (= (cdr pr) "")
      ;; 空值删掉对应键，下次启动回落到默认值
      (vl-catch-all-apply 'vl-registry-delete (list (bp:reg-key) (car pr)))
      (if (vl-catch-all-error-p
            (vl-catch-all-apply 'vl-registry-write
              (list (bp:reg-key) (car pr) (cdr pr))))
        (setq ok nil)
      )
    )
  )
  ok
)

(defun bp:cfgv (k / pr)
  (setq pr (assoc k *bp:cfg*))
  (if pr (cdr pr) "")
)

(defun bp:cfg-put (k v / pr)
  (setq pr (assoc k *bp:cfg*))
  (if pr
    (setq *bp:cfg* (subst (cons k v) pr *bp:cfg*))
    (setq *bp:cfg* (append *bp:cfg* (list (cons k v))))
  )
  v
)

(defun bp:cfg-init ( / v)
  (setq *bp:cfg* (bp:cfg-defaults))
  (foreach pr *bp:cfg*
    (setq v (vl-catch-all-apply 'vl-registry-read (list (bp:reg-key) (car pr))))
    (if (and (not (vl-catch-all-error-p v)) (= (type v) 'STR))
      (bp:cfg-put (car pr) v)
    )
  )
  *bp:cfg*
)



(defun bp:report ()
  (bp:say (strcat "\n  纸张            : " (bp:cfgv "PAPER")))
  (bp:say (strcat "\n  比例            : " (bp:cfgv "SCALE")))
  (bp:say (strcat "\n  打印样式表      : "
                  (if (= (bp:cfgv "STYLESHEET") "") "(沿用布局)" (bp:cfgv "STYLESHEET")))
  )
  (bp:say (strcat "\n  输出目录        : "
                  (if (= (bp:cfgv "OUTDIR") "") "(源目录/PDF)" (bp:cfgv "OUTDIR")))
  )
  (bp:say (strcat "\n  包含模型空间    : "
                  (if (= (bp:cfgv "INCMODEL") "1") "是" "否")))
  (bp:say (strcat "\n  跳过空布局      : "
                  (if (= (bp:cfgv "SKIPEMPTY") "1") "是" "否")))
  (bp:say (strcat "\n  BPF含子文件夹   : "
                  (if (= (bp:cfgv "SUB") "1") "是" "否")))
  (bp:say (strcat "\n  文件名前缀/后缀 : [" (bp:cfgv "PREFIX") "] [" (bp:cfgv "SUFFIX") "]"))
  (bp:say (strcat "\n  完成后开目录    : "
                  (if (= (bp:cfgv "OPEN") "1") "是" "否")))
  (bp:say (strcat "\n  出图引擎        : " (bp:cfgv "ENGINE")))
  (princ)
)

;;; ------------------------------------------------------------------
;;; 三、纸张（图纸尺寸）名称
;;;    DWG To PDF.pc3 的尺寸名随 AutoCAD 语言版本不同，
;;;    采用“候选名 + 回读校验”的方式设置，不依赖查询接口
;;; ------------------------------------------------------------------

(defun bp:media-cands (paper / p)
  (setq p (strcase (bp:trim paper)))
  (cond
    ((= p "A0") '("ISO_A0_(1189.00_x_841.00_MM)" "ISO_full_bleed_A0_(1189.00_x_841.00_MM)"))
    ((= p "A1") '("ISO_A1_(841.00_x_594.00_MM)" "ISO_full_bleed_A1_(841.00_x_594.00_MM)"))
    ((= p "A2") '("ISO_A2_(594.00_x_420.00_MM)" "ISO_full_bleed_A2_(594.00_x_420.00_MM)"))
    ((= p "A3") '("ISO_A3_(420.00_x_297.00_MM)" "ISO_full_bleed_A3_(420.00_x_297.00_MM)"))
    ((= p "A4") '("ISO_A4_(210.00_x_297.00_MM)" "ISO_full_bleed_A4_(210.00_x_297.00_MM)"))
    ((= p "LETTER") '("ANSI_A_(11.00_x_8.50_Inches)" "ANSI_A_(8.50_x_11.00_Inches)"))
    (T nil)
  )
)

;; 设置纸张并回读校验，返回成功使用的尺寸名（nil 表示没设置/失败）
(defun bp:set-media (lay paper / cands c got ok)
  (setq cands (bp:media-cands paper))
  (setq ok nil)
  (if cands
    (foreach c cands
      (if (not ok)
        (progn
          (vl-catch-all-apply (quote vla-put-CanonicalMediaName) (list lay c))
          (setq got (vl-catch-all-apply (quote vla-get-CanonicalMediaName) (list lay)))
          (if (and (not (vl-catch-all-error-p got))
                   (= (strcase got) (strcase c)))
            (setq ok c)
          )
        )
      )
    )
  )
  ok
)

;;; ------------------------------------------------------------------
;;; 四、布局准备与单布局出图
;;; ------------------------------------------------------------------

(defun bp:prep-layout (lay / ss)
  ;; 1) 换打印设备
  (vl-catch-all-apply (quote vla-put-ConfigName) (list lay *bp:dev*))
  ;; 2) 换纸张（必须在换设备之后，否则尺寸名失效）；AUTO 时保持原纸张
  (if (not (bp:set-media lay (bp:cfgv "PAPER")))
    (if (/= (strcase (bp:trim (bp:cfgv "PAPER"))) "AUTO")
      (bp:say (strcat "\n  [提示] 未能设置为 " (bp:cfgv "PAPER") "，沿用该布局原纸张"))
    )
  )
  ;; 3) 打印样式表
  (setq ss (bp:cfgv "STYLESHEET"))
  (if (and ss (/= ss "") (findfile ss))
    (vl-catch-all-apply (quote vla-put-StyleSheet) (list lay ss))
  )
  ;; 4) 可选：布满图纸
  (if (= (strcase (bp:cfgv "SCALE")) "FIT")
    (progn
      (vl-catch-all-apply (quote vla-put-UseStandardScale) (list lay :vlax-true))
      (vl-catch-all-apply (quote vla-put-StandardScale) (list lay 0))
    )
  )
  ;; 5) 保证打印样式/线宽生效
  (vl-catch-all-apply (quote vla-put-PlotWithPlotStyles) (list lay :vlax-true))
  T
)

;; ---------- 引擎 1：ActiveX PlotToFile（默认） ----------
(defun bp:plot-com (lay file / res)
  (setq res (vl-catch-all-apply (quote vla-PlotToFile) (list lay file *bp:dev*)))
  (cond
    ((vl-catch-all-error-p res) (cons nil (vl-catch-all-error-message res)))
    ((bp:filep file) (cons T nil))
    (T (cons nil "未生成 PDF（打印设备或页面设置异常）"))
  )
)

;; ---------- 引擎 2：-PLOT 命令行（备选，适用于 PlotToFile 被阻塞的机器） ----------
;; 全部回车，沿用该布局现有页面设置；仅指定设备、布局与文件名
(defun bp:plot-cmd (lay file / nm ans res)
  (setq nm (vl-catch-all-apply (quote vla-get-Name) (list lay)))
  (if (vl-catch-all-error-p nm) (setq nm nil))
  (setq ans
    (append
      (list "_.-PLOT" nm *bp:dev*)
      (list "" "" "" "" "" "" "" "" "" "" "" "")   ; 提示 3~14：尺寸/方向/区域/比例/样式/线宽等
      (list file)                                  ; 提示 15：文件名
      (list "" "" "")                              ; 提示 16~18：打印到文件/保存页面设置/继续
    )
  )
  (setq res (vl-catch-all-apply (quote apply) (list (quote command) ans)))
  (cond
    ((vl-catch-all-error-p res) (cons nil (vl-catch-all-error-message res)))
    ((bp:filep file) (cons T nil))
    (T (cons nil "未生成 PDF（-PLOT 模式提示序列可能与当前版本不符）"))
  )
)

(defun bp:plot-layout (lay file / )
  (if (bp:filep file) (vl-catch-all-apply (quote vl-file-delete) (list file)))
  (if (= (strcase (bp:cfgv "ENGINE")) "PLOT")
    (bp:plot-cmd lay file)
    (bp:plot-com lay file)
  )
)

;; 同名文件加序号
(defun bp:uniq (dir base / f i)
  (setq i 0)
  (setq f (strcat (bp:dirf dir) base ".pdf"))
  (while (bp:filep f)
    (setq i (1+ i))
    (setq f (strcat (bp:dirf dir) base "(" (itoa i) ").pdf"))
  )
  f
)

;;; ------------------------------------------------------------------
;;; 五、布局枚举
;;; ------------------------------------------------------------------

(defun bp:model-p (lay / nm)
  (setq nm (strcase (vla-get-Name lay)))
  (or (= nm "MODEL") (= nm "模型") (= nm "MODELL"))
)

(defun bp:lay-empty-p (lay / cnt blk)
  (setq cnt 0)
  (setq blk (vl-catch-all-apply 'vla-get-Block (list lay)))
  (if (not (vl-catch-all-error-p blk))
    (vlax-for o blk (setq cnt (1+ cnt)))
  )
  (<= cnt 0)
)

(defun bp:list-layouts (doc incmodel / out)
  (setq out nil)
  (vlax-for lay (vla-get-Layouts doc)
    (if (or (= incmodel 1) (not (bp:model-p lay)))
      (setq out (cons lay out))
    )
  )
  (reverse out)
)

;;; ------------------------------------------------------------------
;;; 六、输出目录
;;; ------------------------------------------------------------------

(defun bp:doc-dir (doc / f)
  (setq f (vl-catch-all-apply 'vla-get-FullName (list doc)))
  (cond
    ((or (vl-catch-all-error-p f) (= f "")) (bp:strip-slash (getvar "MYDOCUMENTSPREFIX")))
    ((null (vl-filename-directory f)) (bp:strip-slash (getvar "MYDOCUMENTSPREFIX")))
    (T (bp:strip-slash (vl-filename-directory f)))
  )
)

(defun bp:resolve-out (src / o)
  (setq o (bp:trim (bp:cfgv "OUTDIR")))
  (cond
    ((= o "") (bp:fullpath (strcat (bp:dirf src) "PDF")))
    ((= (strcase o) "AUTO") (bp:fullpath src))
    (T (bp:fullpath o))
  )
)

;;; ------------------------------------------------------------------
;;; 七、日志 / 系统变量保护
;;; ------------------------------------------------------------------

(defun bp:logline (label nm file result)
  (if *bp:logf*
    (write-line
      (strcat (bp:now) "\t" label "\t" nm "\t" file "\t" result)
      *bp:logf*
    )
  )
)

(defun bp:begin (outdir title)
  (setq *bp:oldbg* (getvar "BACKGROUNDPLOT"))
  (vl-catch-all-apply 'setvar (list "BACKGROUNDPLOT" 0))
  (setq *bp:oldproxy* (getvar "PROXYNOTICE"))
  (vl-catch-all-apply 'setvar (list "PROXYNOTICE" 0))
  (setq *bp:olderr* *error*)
  (setq *error* bp:err)
  (setq *bp:logf*
        (open (strcat (bp:dirf outdir) "批量打印日志_" (bp:stamp) ".txt") "w"))
  (if *bp:logf*
    (write-line "时间\t图纸\t布局\tPDF文件\t结果" *bp:logf*)
  )
  (bp:say (strcat "\n" title))
  (bp:say (strcat "\n[输出目录] " outdir))
  (princ)
)

(defun bp:err (msg)
  (if *bp:oldbg* (vl-catch-all-apply 'setvar (list "BACKGROUNDPLOT" *bp:oldbg*)))
  (if *bp:oldproxy* (vl-catch-all-apply 'setvar (list "PROXYNOTICE" *bp:oldproxy*)))
  (if *bp:logf* (progn (close *bp:logf*) (setq *bp:logf* nil)))
  (setq *error* *bp:olderr*)
  (princ)
)

(defun bp:end (ok fail outdir)
  (if *bp:logf*
    (progn
      (write-line
        (strcat (bp:now) "\t合计\t-\t-\t成功 " (itoa ok) " 失败 " (itoa fail))
        *bp:logf*
      )
      (close *bp:logf*)
      (setq *bp:logf* nil)
    )
  )
  (if *bp:oldbg* (vl-catch-all-apply 'setvar (list "BACKGROUNDPLOT" *bp:oldbg*)))
  (if *bp:oldproxy* (vl-catch-all-apply 'setvar (list "PROXYNOTICE" *bp:oldproxy*)))
  (setq *error* *bp:olderr*)
  (bp:say (strcat "\n[完成] 成功 " (itoa ok) " 个，失败 " (itoa fail) " 个"))
  (bp:say (strcat "\n[输出目录] " outdir))
  (if (and (= (bp:cfgv "OPEN") "1") (> ok 0))
    (vl-catch-all-apply 'startapp (list "explorer" (bp:fullpath outdir)))
  )
  (princ)
)

;;; ------------------------------------------------------------------
;;; 八、单个文档的批处理
;;; ------------------------------------------------------------------

(defun bp:batch-doc (doc outdir label / lays ok fail n nm base file res)
  (setq ok 0 fail 0 n 0)
  (setq lays (bp:list-layouts doc (bp:int-of (bp:cfgv "INCMODEL")))
  (cond
    ((null lays) (bp:say "\n  [提示] 未找到可打印的布局"))
    (T
      (foreach lay lays
        (setq nm (vla-get-Name lay))
        (setq n (1+ n))
        (cond
          ;; 空布局
          ((and (= (bp:cfgv "SKIPEMPTY") "1") (bp:lay-empty-p lay))
            (bp:say (strcat "\n  [跳过] (" (itoa n) ") " nm " -- 空布局"))
            (bp:logline label nm "-" "跳过(空布局)")
          )
          (T
            (bp:prep-layout lay)
            (setq base (strcat (bp:cfgv "PREFIX")
                               (bp:clean label) "-"
                               (bp:clean nm)
                               (bp:cfgv "SUFFIX")
                       )
            )
            (setq file (bp:uniq outdir base))
            (setq res (bp:plot-layout lay file))
            (cond
              ((car res)
                (setq ok (1+ ok))
                (bp:say (strcat "\n  [成功] (" (itoa n) ") " nm "  ->  " file))
                (bp:logline label nm file "成功")
              )
              (T
                (setq fail (1+ fail))
                (bp:say (strcat "\n  [失败] (" (itoa n) ") " nm "  :  " (cdr res)))
                (bp:logline label nm "-" (strcat "失败:" (cdr res)))
              )
            )
          )
        )
      )
    )
  )
  (cons ok fail)
)

;; 是否已在当前 CAD 会话中打开
(defun bp:is-open (path / res nm)
  (setq res nil)
  (vlax-for d (vla-get-Documents (bp:app))
    (setq nm (vl-catch-all-apply 'vla-get-FullName (list d)))
    (if (and (not (vl-catch-all-error-p nm))
             (/= nm "")
             (= (strcase (bp:fullpath nm)) (strcase (bp:fullpath path))
        )
      (setq res T)
    )
  )
  res
)

;;; ------------------------------------------------------------------
;;; 九、命令 BP：当前图纸全部布局
;;; ------------------------------------------------------------------

(defun c:BP ( / doc dir name outdir res)
  (bp:cfg-init)
  (setq doc (bp:doc))
  (setq dir (bp:strip-slash (getvar "DWGPREFIX")))
  (setq name (vl-filename-base (getvar "DWGNAME")))
  (if (= name "") (setq name "Drawing"))
  (setq outdir (bp:resolve-out dir))

  (cond
    ((not (bp:mkdirs outdir))
      (bp:say (strcat "\n[错误] 无法创建输出目录: " outdir))
    )
    (T
      (bp:begin outdir
        (strcat "[批量打印] 当前图纸所有布局 -> PDF  《" name ".dwg》"))
      (setq res (bp:batch-doc doc outdir name))
      (bp:end (car res) (cdr res) outdir)
    )
  )
  (princ)
)

;;; ------------------------------------------------------------------
;;; 十、命令 BPF：整个文件夹（可含子文件夹）
;;; ------------------------------------------------------------------

(defun bp:dwg-files (dir sub / out lst d)
  (setq out nil)
  (setq lst (vl-directory-files dir "*.dwg" 1))
  (foreach f lst
    (setq out (cons (strcat (bp:dirf dir) f) out))
  )
  (if sub
    (foreach d (vl-directory-files dir nil -1)
      (if (and (/= d ".") (/= d ".."))
        (setq out (append (bp:dwg-files (strcat (bp:dirf dir) d) T) out))
      )
    )
  )
  out
)

(defun bp:ask-folder ( / d p)
  (setq d (bp:strip-slash (getvar "DWGPREFIX")))
  (setq p (bp:trim (getstring T (strcat "\n[批量打印] 目标文件夹（回车=当前图纸目录 " d "）: "))))
  (cond
    ((= p "") d)
    ((vl-filename-extension p) (bp:strip-slash (vl-filename-directory p)))
    (T (bp:strip-slash (bp:fullpath p)))
  )
)

(defun c:BPF ( / folder outdir files path label ndoc res ok fail orig cnt total)
  (bp:cfg-init)
  (setq ok 0 fail 0 cnt 0)

  (setq folder (bp:ask-folder))
  (cond
    ((not (vl-file-directory-p folder))
      (bp:say (strcat "\n[错误] 文件夹不存在: " folder))
    )
    (T
      (setq outdir (bp:resolve-out folder))
      (if (not (bp:mkdirs outdir))
        (bp:say (strcat "\n[错误] 无法创建输出目录: " outdir))
        (progn
          (setq files (bp:dwg-files folder (= (bp:cfgv "SUB") "1")))
          (cond
            ((null files) (bp:say "\n[提示] 该文件夹内没有 DWG 文件"))
            (T
              (setq orig (bp:doc))
              (setq total (length files))
              (bp:begin outdir
                (strcat "[批量打印] 文件夹批量打印 -> PDF，共 " (itoa total) " 个 DWG"))
              (foreach path files
                (setq cnt (1+ cnt))
                (setq label (vl-filename-base path))
                (bp:say (strcat "\n(" (itoa cnt) "/" (itoa total) ") " label ".dwg"))
                (cond
                  ((bp:is-open path)
                    (bp:say "\n  [跳过] 该图纸已在 CAD 中打开，请关闭后再打印")
                    (setq fail (1+ fail))
                    (bp:logline label "-" "-" "跳过(已打开)")
                  )
                  (T
                    (setq ndoc
                      (vl-catch-all-apply 'vla-open
                        (list (vla-get-Documents (bp:app)) path)
                      )
                    )
                    (cond
                      ((vl-catch-all-error-p ndoc)
                        (bp:say (strcat "\n  [失败] 无法打开: "
                                        (vl-catch-all-error-message ndoc)))
                        (setq fail (1+ fail))
                        (bp:logline label "-" "-" "失败(打开)")
                      )
                      (T
                        (setq res (bp:batch-doc ndoc outdir label))
                        (setq ok (+ ok (car res)))
                        (setq fail (+ fail (cdr res)))
                        ;; 不保存直接关闭
                        (vl-catch-all-apply 'vla-close (list ndoc :vlax-false))
                      )
                    )
                  )
                )
              )
              (vl-catch-all-apply 'vla-activate (list orig))
              (bp:end ok fail outdir)
            )
          )
        )
      )
    )
  )
  (princ)
)

;;; ------------------------------------------------------------------
;;; 十一、设置命令
;;; ------------------------------------------------------------------

(defun bp:prompt-cfg (k label / v cur)
  (setq cur (bp:cfgv k))
  (setq v (bp:trim (getstring T (strcat "\n" label " <" cur ">: "))))
  (if (/= v "") (bp:cfg-put k v))
  (princ)
)

(defun c:BPSET ( / )
  (bp:cfg-init)
  (bp:say "\n===== 批量打印设置（当前值）=====")
  (bp:report)
  (bp:say "\n\n直接回车 = 保持当前值。")
  (bp:prompt-cfg "PAPER"      "纸张 A0/A1/A2/A3/A4/LETTER/AUTO")
  (bp:prompt-cfg "SCALE"      "比例 LAYOUT=沿用布局 / FIT=布满图纸")
  (bp:prompt-cfg "STYLESHEET" "打印样式表(.ctb/.stb)完整路径，空=沿用布局")
  (bp:prompt-cfg "OUTDIR"     "输出目录（空=源目录/PDF，AUTO=源目录）")
  (bp:prompt-cfg "INCMODEL"   "包含模型空间 [1=是 0=否]")
  (bp:prompt-cfg "SKIPEMPTY"  "跳过空布局 [1=是 0=否]")
  (bp:prompt-cfg "SUB"        "BPF含子文件夹 [1=是 0=否]")
  (bp:prompt-cfg "PREFIX"     "文件名前缀")
  (bp:prompt-cfg "SUFFIX"     "文件名后缀")
  (bp:prompt-cfg "OPEN"       "完成后打开输出目录 [1=是 0=否]")
  (bp:prompt-cfg "ENGINE"     "出图引擎 COM=默认 / PLOT=命令行模式（COM 无输出时试这个）")

  ;; 规整大小写后落盘
  (bp:cfg-put "PAPER" (strcase (bp:cfgv "PAPER")))
  (bp:cfg-put "SCALE" (strcase (bp:cfgv "SCALE")))

  (if (bp:cfg-save)
    (bp:say (strcat "\n[完成] 设置已保存（注册表 HKCU\\Software\\Doubao\\BatchPlot）"))
    (bp:say "\n[错误] 设置保存失败，本次设置仅当前会话有效")
  )
  (princ)
)

;;; ------------------------------------------------------------------
;;; 十二、帮助
;;; ------------------------------------------------------------------

(defun c:BPHELP ()
  (bp:say "\n================ 批量打印插件 BatchPlot ================")
  (bp:say "\n BP     当前图纸所有布局批量输出 PDF")
  (bp:say "\n BPF    指定文件夹内所有 DWG 批量输出 PDF（可含子文件夹）")
  (bp:say "\n BPSET  查看/修改设置")
  (bp:say "\n BPHELP 本帮助")
  (bp:say "\n------------------------------------------------------")
  (bp:say "\n 文件名: 前缀 + 图纸名-布局名 + 后缀 + .pdf，同名自动加序号")
  (bp:say "\n 输出目录默认: <图纸所在目录>/PDF")
  (bp:say "\n 每个布局沿用原有页面设置(打印区域/旋转/着色)，仅替换设备与纸张")
  (bp:say "\n 日志: 输出目录下 批量打印日志_时间.txt")
  (bp:say "\n 首次使用建议先 BPSET 设置纸张与比例，再用单张图纸试打")
  (bp:say "\n======================================================")
  (princ)
)

(princ "\nBatchPlot 1.00 已加载。输入 BP / BPF / BPSET / BPHELP 使用。")
(princ)
