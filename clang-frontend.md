# 聊聊Clang前端

## 1 开端

Clang前端的起手是FrontendAction。简单地说这个类只有两个成员，一个CompilerInstance,一个FrontendInputFile。
就是对某个文件，执行某个compiler的功能。

整个初始调用链是3步

```
driver/cc1_main.cpp:cc1_main()
FrontendTool/ExecuteCompilerInvocation.cpp:ExecuteCompilerInvocation()
Frontend/CompilerInstance.cpp:ExecuteAction()
Frontend/FrontendAction.cpp:ExecuteAction()
```

最普通的两个FrontendAction就是PreprocessOnlyAction和ASTFrontendAction.

```cpp
void PreprocessOnlyAction::ExecuteAction() {
  Preprocessor &PP = getCompilerInstance().getPreprocessor();

  // Ignore unknown pragmas.
  PP.IgnorePragmas();

  Token Tok;
  // Start parsing the specified input file.
  PP.EnterMainSourceFile();
  do {
    PP.Lex(Tok);
  } while (Tok.isNot(tok::eof));
}
```

```cpp
void ASTFrontendAction::ExecuteAction() {
  CompilerInstance &CI = getCompilerInstance();
  if (!CI.hasPreprocessor())
    return;
  // This is a fallback: If the client forgets to invoke this, we mark the
  // current stack as the bottom. Though not optimal, this could help prevent
  // stack overflow during deep recursion.
  clang::noteBottomOfStack();

  // FIXME: Move the truncation aspect of this into Sema, we delayed this till
  // here so the source manager would be initialized.
  if (hasCodeCompletionSupport() &&
      !CI.getFrontendOpts().CodeCompletionAt.FileName.empty())
    CI.createCodeCompletionConsumer();

  // Use a code completion consumer?
  CodeCompleteConsumer *CompletionConsumer = nullptr;
  if (CI.hasCodeCompletionConsumer())
    CompletionConsumer = &CI.getCodeCompletionConsumer();

  if (!CI.hasSema())
    CI.createSema(getTranslationUnitKind(), CompletionConsumer);

  ParseAST(CI.getSema(), CI.getFrontendOpts().ShowStats,
           CI.getFrontendOpts().SkipFunctionBodies);
}
```

## 2 构建AST

我们已经看到，PreprocessOnlyAction只需要一个Preprocessor,

1. PP.EnterMainSourceFile()
2. 不停地执行`PP.Lex(Tok)`
3. 直到EOF。

而ASTFrontendAction则创建了Sema并调用ParseAST

```cpp
void clang::ParseAST(Sema &S, bool PrintStats, bool SkipFunctionBodies) {
  // Collect global stats on Decls/Stmts (until we have a module streamer).
  if (PrintStats) {
    Decl::EnableStatistics();
    Stmt::EnableStatistics();
  }

  // Also turn on collection of stats inside of the Sema object.
  bool OldCollectStats = PrintStats;
  std::swap(OldCollectStats, S.CollectStats);

  // Initialize the template instantiation observer chain.
  // FIXME: See note on "finalize" below.
  initialize(S.TemplateInstCallbacks, S);

  ASTConsumer *Consumer = &S.getASTConsumer();

  std::unique_ptr<Parser> ParseOP(
      new Parser(S.getPreprocessor(), S, SkipFunctionBodies));
  Parser &P = *ParseOP.get();

  llvm::CrashRecoveryContextCleanupRegistrar<const void, ResetStackCleanup>
      CleanupPrettyStack(llvm::SavePrettyStackState());
  PrettyStackTraceParserEntry CrashInfo(P);

  // Recover resources if we crash before exiting this method.
  llvm::CrashRecoveryContextCleanupRegistrar<Parser>
    CleanupParser(ParseOP.get());

  S.getPreprocessor().EnterMainSourceFile();
  ExternalASTSource *External = S.getASTContext().getExternalSource();
  if (External)
    External->StartTranslationUnit(Consumer);

  // If a PCH through header is specified that does not have an include in
  // the source, or a PCH is being created with #pragma hdrstop with nothing
  // after the pragma, there won't be any tokens or a Lexer.
  bool HaveLexer = S.getPreprocessor().getCurrentLexer();

  if (HaveLexer) {
    llvm::TimeTraceScope TimeScope("Frontend");
    P.Initialize();
    Parser::DeclGroupPtrTy ADecl;
    Sema::ModuleImportState ImportState;
    EnterExpressionEvaluationContext PotentiallyEvaluated(
        S, Sema::ExpressionEvaluationContext::PotentiallyEvaluated);

    for (bool AtEOF = P.ParseFirstTopLevelDecl(ADecl, ImportState); !AtEOF;
         AtEOF = P.ParseTopLevelDecl(ADecl, ImportState)) {
      // If we got a null return and something *was* parsed, ignore it.  This
      // is due to a top-level semicolon, an action override, or a parse error
      // skipping something.
      if (ADecl && !Consumer->HandleTopLevelDecl(ADecl.get()))
        return;
    }
  }

  // Process any TopLevelDecls generated by #pragma weak.
  for (Decl *D : S.WeakTopLevelDecls())
    Consumer->HandleTopLevelDecl(DeclGroupRef(D));

  Consumer->HandleTranslationUnit(S.getASTContext());

  // Finalize the template instantiation observer chain.
  // FIXME: This (and init.) should be done in the Sema class, but because
  // Sema does not have a reliable "Finalize" function (it has a
  // destructor, but it is not guaranteed to be called ("-disable-free")).
  // So, do the initialization above and do the finalization here:
  finalize(S.TemplateInstCallbacks, S);

  std::swap(OldCollectStats, S.CollectStats);
  if (PrintStats) {
    llvm::errs() << "\nSTATISTICS:\n";
    if (HaveLexer) P.getActions().PrintStats();
    S.getASTContext().PrintStats();
    Decl::PrintStats();
    Stmt::PrintStats();
    Consumer->PrintStats();
  }
}
```

我们看到这里面的情况是

1. PP.EnterMainSourceFile()
2. 不停 P.ParseTopLevelDecl,并喂给Consumer
3. 直到EOF，并再喂Consumer一次

这里出现了一个新的概念，Parser。

## 3 Parser

整个前端的复杂度基本上都在Parser,例如，对PP.Lex()做了这么几种封装

```cpp
SourceLocation ConsumeToken()
SourceLocation ConsumeParen()
SourceLocation ConsumeBracket()
SourceLocation ConsumeBrace() 
SourceLocation ConsumeStringToken()
SourceLocation ConsumeCodeCompletionToken()
SourceLocation ConsumeAnnotationToken()
bool TryConsumeToken(tok::TokenKind Expected)
void UnconsumeToken(Token &Consumed)
```

在此之上，Parser有时候还直接调用PP.Lex()，是可忍，孰不可忍。

再比如，Parser中有这样一个类

```cpp
  /// TentativeParsingAction - An object that is used as a kind of "tentative
  /// parsing transaction". It gets instantiated to mark the token position and
  /// after the token consumption is done, Commit() or Revert() is called to
  /// either "commit the consumed tokens" or revert to the previously marked
  /// token position. Example:
  ///
  ///   TentativeParsingAction TPA(*this);
  ///   ConsumeToken();
  ///   ....
  ///   TPA.Revert();
  ///
  class TentativeParsingAction {
    Parser &P;
    PreferredTypeBuilder PrevPreferredType;
    Token PrevTok;
    size_t PrevTentativelyDeclaredIdentifierCount;
    unsigned short PrevParenCount, PrevBracketCount, PrevBraceCount;
    bool isActive;

  public:
    explicit TentativeParsingAction(Parser &p)
        : P(p), PrevPreferredType(P.PreferredType) {
      PrevTok = P.Tok;
      PrevTentativelyDeclaredIdentifierCount =
          P.TentativelyDeclaredIdentifiers.size();
      PrevParenCount = P.ParenCount;
      PrevBracketCount = P.BracketCount;
      PrevBraceCount = P.BraceCount;
      P.PP.EnableBacktrackAtThisPos();
      isActive = true;
    }
    void Commit() {
      assert(isActive && "Parsing action was finished!");
      P.TentativelyDeclaredIdentifiers.resize(
          PrevTentativelyDeclaredIdentifierCount);
      P.PP.CommitBacktrackedTokens();
      isActive = false;
    }
    void Revert() {
      assert(isActive && "Parsing action was finished!");
      P.PP.Backtrack();
      P.PreferredType = PrevPreferredType;
      P.Tok = PrevTok;
      P.TentativelyDeclaredIdentifiers.resize(
          PrevTentativelyDeclaredIdentifierCount);
      P.ParenCount = PrevParenCount;
      P.BracketCount = PrevBracketCount;
      P.BraceCount = PrevBraceCount;
      isActive = false;
    }
    ~TentativeParsingAction() {
      assert(!isActive && "Forgot to call Commit or Revert!");
    }
  };
```

Parser除了利用PP,还利用Sema,来构建AST,，进行类型检查等。可以看`Parser.h`的include

```cpp
#include "clang/AST/Availability.h"
#include "clang/Basic/BitmaskEnum.h"
#include "clang/Basic/OpenMPKinds.h"
#include "clang/Basic/OperatorPrecedence.h"
#include "clang/Basic/Specifiers.h"
#include "clang/Basic/TokenKinds.h"
#include "clang/Lex/CodeCompletionHandler.h"
#include "clang/Lex/Preprocessor.h"
#include "clang/Sema/DeclSpec.h"
#include "clang/Sema/Sema.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Frontend/OpenMP/OMPContext.h"
#include "llvm/Support/Compiler.h"
#include "llvm/Support/PrettyStackTrace.h"
#include "llvm/Support/SaveAndRestore.h"
#include <memory>
#include <optional>
#include <stack>
```
