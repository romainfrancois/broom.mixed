#' Tidying methods for glmmADMB models
#'
#' These methods tidy the coefficients of \code{glmmADMB} models
#'
#' @param x An object of class \code{glmmadmb}
#' \code{glmer}, or \code{nlmer}
#'
#' @return All tidying methods return a \code{tbl_df} without rownames.
#' The structure depends on the method chosen.
#'
#' @name glmmadmb_tidiers
#' @aliases glmmADMB_tidiers
#'
#' @examples
#'
#' if (require("glmmADMB") && require("lme4")) {
#'     ## original model
#'     \dontrun{
#'         data("sleepstudy", package="lme4")
#'         lmm1 <- glmmadmb(Reaction ~ Days + (Days | Subject), sleepstudy,
#'                          family="gaussian")
#'     }
#'     ## load stored object
#'     load(system.file("extdata","glmmADMB_example.rda",package="broom.mixed"))
#'     tidy(lmm1, effects = "fixed")
#'     tidy(lmm1, effects = "fixed", conf.int=TRUE)
#'     ## tidy(lmm1, effects = "fixed", conf.int=TRUE, conf.method="profile")
#'     ## tidy(lmm1, effects = "ran_vals", conf.int=TRUE)
#'     head(augment(lmm1, sleepstudy))
#'     glance(lmm1)
#'
#'     glmm1 <- glmmadmb(cbind(incidence, size - incidence) ~ period + (1 | herd),
#'                   data = cbpp, family = "binomial")
#'     tidy(glmm1)
#'     tidy(glmm1, effects = "fixed")
#'     head(augment(glmm1, cbpp))
#'     glance(glmm1)
#'
#' }
NULL

#' @rdname glmmadmb_tidiers
#'
#' @param component Which component(s) to report for (e.g., conditional, zero-inflation, dispersion: at present only works for "cond")
#' @param effects A character vector including one or more of "fixed" (fixed-effect parameters), "ran_pars" (variances and covariances or standard deviations and correlations of random effect terms) or "ran_vals" (conditional modes/BLUPs/latent variable estimates)
#' @param conf.int whether to include a confidence interval
#' @param conf.level confidence level for CI
#' @param conf.method method for computing confidence intervals (see \code{\link[lme4]{confint.merMod}})
#' @param scales scales on which to report the variables: for random effects, the choices are \sQuote{"sdcor"} (standard deviations and correlations: the default if \code{scales} is \code{NULL}) or \sQuote{"varcov"} (variances and covariances). \code{NA} means no transformation, appropriate e.g. for fixed effects; inverse-link transformations (exponentiation
#' or logistic) are not yet implemented, but may be in the future.
#' @param ran_prefix a length-2 character vector specifying the strings to use as prefixes for self- (variance/standard deviation) and cross- (covariance/correlation) random effects terms
#'
#' @return \code{tidy} returns one row for each estimated effect, either
#' with groups depending on the \code{effects} parameter.
#' It contains the columns
#'   \item{group}{the group within which the random effect is being estimated: \code{NA} for fixed effects}
#'   \item{level}{level within group (\code{NA} except for modes)}
#'   \item{term}{term being estimated}
#'   \item{estimate}{estimated coefficient}
#'   \item{std.error}{standard error}
#'   \item{statistic}{t- or Z-statistic (\code{NA} for modes)}
#'   \item{p.value}{P-value computed from t-statistic (may be missing/NA)}
#'
#' @importFrom plyr ldply rbind.fill
#' @import dplyr
#' @importFrom tidyr gather spread
#' @importFrom nlme VarCorr ranef
#'
#' @export
tidy.glmmadmb <- function(x, effects = c("fixed", "ran_pars"),
                          component = "cond",
                          scales = NULL, ## c("sdcor",NA),
                          ran_prefix = NULL,
                          conf.int = FALSE,
                          conf.level = 0.95,
                          conf.method = "Wald",
                          ...) {

  ## FIXME: refactor/clean up!
  ## R CMD check false positives
  term <- estimate <- .id <- level <- std.error <- NULL

  if (length(component) > 1 || component != "cond") {
    stop("only works for conditional component")
  }
  if (conf.method != "Wald") stop("only Wald CIs available")
  effect_names <- c("ran_pars", "fixed", "ran_vals")
  if (!is.null(scales)) {
    if (length(scales) != length(effects)) {
      stop(
        "if scales are specified, values (or NA) must be provided ",
        "for each effect"
      )
    }
  }
  if (length(miss <- setdiff(effects, effect_names)) > 0) {
    stop("unknown effect type ", miss)
  }
  ret_list <- list()
  if ("fixed" %in% effects) {
    # return tidied fixed effects rather than random
    ret <- (stats::coef(summary(x))
    %>%
      as.data.frame()
      %>%
      rownames_to_column(var = "term")
      %>%
      rename_cols()
    )

    if (conf.int) {
      cifix <- (confint(x)
      %>%
        dplyr::as_tibble()
        %>%
        setNames(c("conf.low", "conf.high"))
      )
      ret <- dplyr::bind_cols(ret, cifix)
    }
    ret_list$fixed <- ret
  }
  if ("ran_pars" %in% effects) {
    if (is.null(scales)) {
      rscale <- "sdcor"
    } else {
      rscale <- scales[effects == "ran_pars"]
    }
    if (!rscale %in% c("sdcor", "vcov")) {
      stop(sprintf("unrecognized ran_pars scale %s", sQuote(rscale)))
    }
    vv <- VarCorr(x)
    vv <- lapply(
      vv,
      function(v) {
        attr(v, "stddev") <- sqrt(diag(v))
        attr(v, "correlation") <- stats::cov2cor(v)
        v
      }
    )
    if (useSc <- (x$family == "gaussian")) {
      attr(vv, "sc") <- x$alpha
    }
    attr(vv, "useSc") <- useSc
    class(vv) <- "VarCorr.merMod"
    ## hack ...
    vv2 <- (dplyr::as_tibble(as.data.frame(vv))
    %>%
      mutate_if(is.factor, as.character)
    )
    if (is.null(ran_prefix)) {
      ran_prefix <- switch(rscale,
        vcov = c("var", "cov"),
        sdcor = c("sd", "cor")
      )
    }
    pfun <- function(x) {
      v <- na.omit(unlist(x))
      if (length(v) == 0) v <- "Observation"
      p <- paste(v, collapse = ".")
      if (!identical(ran_prefix, NA)) {
        p <- paste(ran_prefix[length(v)], p, sep = "_")
      }
      return(p)
    }
    term <- paste(apply(vv2[c("var1", "var2")], 1, pfun),
      vv2[["grp"]],
      sep = "."
    )

    estimate <- vv2[[rscale]]
    ret <- dplyr::tibble(group = vv2$grp, term, estimate)


    if (conf.int) {
      warning("confint not implemented for glmmADMB ran_pars")
      ## ciran <- confint(x,parm="theta_",method=conf.method,...)
      ret <- mutate(ret, conf.low = NA, conf.high = NA)
      ## nn <- c(nn,"conf.low","conf.high")
    }

    ret_list$ran_pars <- ret
  }
  if ("ran_vals" %in% effects) {
    ## fix each group to be a tidy data frame

    nn <- c("estimate", "std.error")
    re <- ranef(x, condVar = TRUE)
    getSE <- function(x) {
      v <- attr(x, "postVar")
      setNames(
        as.data.frame(sqrt(t(apply(v, 3, diag)))),
        colnames(x)
      )
    }
    fix <- function(g, re, .id) {
      newg <- fix_data_frame(g, newnames = colnames(g), newcol = "level")
      # fix_data_frame doesn't create a new column if rownames are numeric,
      # which doesn't suit our purposes
      newg$level <- rownames(g)
      newg$type <- "estimate"

      newg.se <- getSE(re)
      newg.se$level <- rownames(re)
      newg.se$type <- "std.error"

      data.frame(rbind(newg, newg.se),
        .id = .id,
        check.names = FALSE
      )
      ## prevent coercion of variable names
    }

    mm <- bind_rows(Map(fix, coef(x), re, names(re)))

    ## block false-positive warnings due to NSE
    type <- spread <- est <- NULL
    mm %>%
      gather(term, estimate, -.id, -level, -type) %>%
      spread(type, estimate) -> ret

    ## FIXME: doesn't include uncertainty of population-level estimate

    if (conf.int) {
      if (conf.method != "Wald") {
        stop("only Wald CIs available for conditional modes")
      }

      mult <- qnorm((1 + conf.level) / 2)
      ret <- transform(ret,
        conf.low = estimate - mult * std.error,
        conf.high = estimate + mult * std.error
      )
    }

    ret <- dplyr::rename(ret, grp = .id)
    ret_list$ran_vals <- ret
  }
  ret <- (bind_rows(ret_list, .id = "effect")
  %>%
    as_tibble() ## FIXME: upstream?
  %>%
    reorder_cols()
  )
  return(ret)
}



#' @rdname glmmadmb_tidiers
#'
#' @param data original data this was fitted on; if not given this will
#' attempt to be reconstructed
#' @param newdata new data to be used for prediction; optional
#'
#' @template augment_NAs
#'
#' @return \code{augment} returns one row for each original observation,
#' with columns (each prepended by a .) added. Included are the columns
#'   \item{.fitted}{predicted values}
#'   \item{.resid}{residuals}
#'   \item{.fixed}{predicted values with no random effects}
#'
#' Also added for "merMod" objects, but not for "mer" objects,
#' are values from the response object within the model (of type
#' \code{lmResp}, \code{glmResp}, \code{nlsResp}, etc). These include \code{".mu",
#' ".offset", ".sqrtXwt", ".sqrtrwt", ".eta"}.
#'
#' @export
augment.glmmadmb <- function(x, data = stats::model.frame(x), newdata, ...) {
  # move rownames if necessary
  if (missing(newdata)) {
    newdata <- NULL
  }
  ## hack: glmmADMB residuals may be a 1-column matrix, which
  ##  breaks check_tibble() (!)
  x$residuals <- c(x$residuals)
  ret <- augment_columns(x, data, newdata, se.fit = NULL)

  # add predictions with no random effects (population means)
  predictions <- stats::predict(x, re.form = NA)
  # some cases, such as values returned from nlmer, return more than one
  # prediction per observation. Not clear how those cases would be tidied
  if (length(predictions) == nrow(ret)) {
    ret$.fixed <- predictions
  }

  # columns to extract from resp reference object
  # these include relevant ones that could be present in lmResp, glmResp,
  # or nlsResp objects

  ## respCols <- c("mu", "offset", "sqrtXwt", "sqrtrwt", "weights", "wtres", "gam", "eta")
  ## cols <- lapply(respCols, function(n) x@resp[[n]])
  ## names(cols) <- paste0(".", respCols)
  ## cols <- as.data.frame(compact(cols))  # remove missing fields

  ## cols <- insert_NAs(cols, ret)
  ## if (length(cols) > 0) {
  ## ret <- cbind(ret, cols)
  ## }

  unrowname(ret)
}


#' @rdname glmmadmb_tidiers
#'
#' @param ... extra arguments (not used)
#'
#' @return \code{glance} returns one row with the columns
#'   \item{sigma}{the square root of the estimated residual variance}
#'   \item{logLik}{the data's log-likelihood under the model}
#'   \item{AIC}{the Akaike Information Criterion}
#'   \item{BIC}{the Bayesian Information Criterion}
#'   \item{deviance}{deviance}
#'
#' @export
glance.glmmadmb <- function(x, ...) {
  ## hack, glmmADMB doesn't have a sigma.glmmADMB method (yet)
  sigma.glmmADMB <- function(x) {
    if (is.null(s <- x$alpha)) s <- NA
    return(s)
  }
  return(finish_glance(x = x))
}
