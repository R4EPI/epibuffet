#' Tabulate survey design objects by a categorical and another stratifying variable
#'
#' This function has been superseeded by [tab_survey()] please use that function
#' instead.
#'
#' @param x a survey design object
#'
#' @param var the bare name of a categorical variable
#'
#' @param strata a variable to stratify the results by
#'
#' @param pretty if `TRUE`, default, the proportion and CI are merged
#'
#' @param wide if `TRUE` (default) and strata is defined, then the results are
#'   presented in a wide table with each stratification counts and estimates in
#'   separate columns. If `FALSE`, then the data will be presented in a long
#'   format where the counts and estimates are presented in single columns. This
#'   has no effect if strata is not defined.
#'
#' @param digits if `pretty = FALSE`, this indicates the number of digits used
#'   for proportion and CI
#'
#' @param method a method from [survey::svyciprop()] to calculate the confidence
#'   interval. Defaults to "logit"
#'
#' @param na.rm When `TRUE`, missing (NA) values present in `var` will be removed
#'   from the data set with a warning, causing a change in denominator for the
#'   tabulations.  The default is set to `FALSE`, which creates an explicit
#'   missing value called "(Missing)".
#'
#' @param deff a logical indicating if the design effect should be reported.
#'   Defaults to "TRUE"
#'
#' @param proptotal if `TRUE` and `strata` is not `NULL`, then the totals of the
#'   rows will be reported as proportions of the total data set, otherwise, they
#'   will be proportions within the stratum (default).
#'
#' @param coltotals if `TRUE` a new row with totals for each "n" column is
#'   created.
#'
#' @param rowtotals if `TRUE` and `strata` is defined, then an extra "Total"
#'   column will be added tabulating all of the rows across strata.
#'
#' @return a long or wide tibble with tabulations n, ci, and deff
#'
#' @keywords internal
#'
#' @seealso [epikit::rename_redundant()], [epikit::augment_redundant()]
#'
#' @importFrom srvyr survey_total survey_mean
tabulate_survey <- function(x, var, strata = NULL, pretty = TRUE, wide = TRUE,
                            digits = 1, method = "logit", na.rm = FALSE, deff = FALSE,
                            proptotal = FALSE, rowtotals = FALSE,
                            coltotals = FALSE) {
  stopifnot(inherits(x, "tbl_svy"))

  # The idea behind this function is the fact that it can get complicated
  # to tabulate survey data with groupings. We originally wanted to lean
  # heavily on the srvyr package for this but ran into problems:
  # https://github.com/gergness/srvyr/issues/49
  #
  # This takes in either character or bare variable names and will return a
  # table similar to that of `descriptive()` with the exception that it also
  # will have confidence intervals and design effects.
  #
  # This will first tabulate the survey total using `srvyr::survey_total()` and
  # grab the design effect with `srvyr::survey_mean()`.
  #
  # Unfortunately, because of the issue above and various other things with
  # srvyr::survey_mean(), it wasn't possible to get proportions for each strata,
  # so we had to roll our own. (See below for more details).
  #
  # After the tabulations are done, the counts are rounded, and the SE columns
  # are removed, the confidence intervals and mean estimates are collapsed into
  # a single column using `prettify_tabulation()`
  #
  # The results are in long data naturally, but if the user requests wide data
  # (which is the default), then the strata are spread out into columns using
  # the widen_tabulation function 

  cod  <- rlang::enquo(var)
  st   <- rlang::enquo(strata)
  vars <- tidyselect::vars_select(colnames(x), !!cod, !! st)
  cod  <- rlang::sym(vars[1])

  null_strata <- is.na(vars[2])
  if (null_strata) {
    st <- st 
  } else {
    st <- rlang::sym(vars[2])
  }

  x <- srvyr::select(x, !!cod, !!st)

  # If the counter variable is numeric or logical, we need to convert it to a
  # factor. For logical variables, this is trivial, so we just do it.
  if (is.logical(x$variables[[vars[1]]])) {
    x <- srvyr::mutate(x, !!cod := factor(!!cod, levels = c("TRUE", "FALSE")))
  }
  # For numeric data, however, we need to warn the user
  if (is.numeric(x$variables[[vars[1]]])) {
    warning(glue::glue("converting `{vars[1]}` to a factor"), call. = FALSE)
    x <- srvyr::mutate(x, !!cod := epikit::fac_from_num(!!cod))
  }

  # if there is missing data, we should treat it by either removing the rows
  # with the missing values or making the missing explicit.
  if (na.rm) {
    nas <- sum(is.na(x$variables[[vars[1]]]))
    if (nas > 0) {
      warning(glue::glue("removing {nas} missing value(s) from `{vars[1]}`"), call. = FALSE)
      x <- srvyr::filter(x, !is.na(!!cod))
    }
  } else {
    x <- srvyr::mutate(x, !!cod := forcats::fct_explicit_na(!!cod, na_level = "(Missing)"))
  }

  # here we are creating a dummy variable that is either the var or the
  # combination of var and strata so that we can get the right proportions from
  # the survey package in a loop below
  if (null_strata) {
    x <- srvyr::group_by(x, !!cod, .drop = FALSE)
  } else {
    # if there is a strata, create a unique, parseable dummy var by inserting
    # the timestamp in between the vars
    tim <- as.character(Sys.time())
    x <- srvyr::group_by(x, !!cod, !!st, .drop = FALSE)
  }

  # Creating counts and design effect columns
  #
  # Wed 25 Sep 2019 12:06:49 BST: I had to add in a trycatch statement here
  # because there was a weird error in srvyr that depended on the order in which
  # the grouping arguments were specified. One way would produce an error when
  # fitting the model that needed factors with 2 or more levels, but the other
  # way would give an answer.
  #
  # This statement explicitly tries to summarize and then, if there is an error
  # and it exactly matches the weirdness, it will try it the other way.
  # Otherwise, it will return the error.
  y <- tryCatch(
    {
      y <- srvyr::summarise(x,
        n    = srvyr::survey_total(vartype = "se", na.rm = TRUE),
        mean = srvyr::survey_mean(na.rm = TRUE, deff = deff)
      )
    },
    warning = function(w) {
      y <- w
      wrn <- 'algorithm did not converge'    
      if (grepl(wrn, w$message, fixed = TRUE)) {
        warning('the GLM did not converge, so estimates and confidence intervals may be less reliable', call. = FALSE)
      } else {
        warning(w)
      }
    },
    # In the case of an error, return the error by default, but try to flip the
    # groups and try again.
    error = function(e) {
      y <- e
      err <- "contrasts can be applied.+?factors.+?2 or more levels"
      if (grepl(err, y$message)) {
        if (!null_strata) {
          x <- group_by(x, !!st, !!cod, .drop = FALSE)
          y <- srvyr::summarise(x,
            n    = srvyr::survey_total(vartype = "se", na.rm = TRUE),
            mean = srvyr::survey_mean(na.rm = TRUE, deff = deff)
          )
        } else {
          stop(e, call. = FALSE)
        }
      } 
      y
    }
  )


  if (!null_strata) {
    y <- dplyr::arrange(y, !!cod, !!st)
    y <- dplyr::select(y, !!cod, !!st, dplyr::everything())
    if (!is.factor(dplyr::pull(y, !!st))) {
      y <- dplyr::mutate(y, !!st := factor(!!st))
    }
  }

  # Removing the mean values here because we are going to calculate them later
  y$mean <- NULL
  y$mean_se <- NULL
  if (deff) {
    names(y)[names(y) == "mean_deff"] <- "deff"
    y$deff[!is.finite(y$deff)] <- NA
  }



  # By this time, we already have a summary table with counts and deff.
  # This will contain one or two columns in the front either being the counting
  # variable (cod) and *maybe* the stratifying variable (st) if it exists.
  #
  # Because survey_mean does not calculate CI for factors using the svypropci,
  # this gives negative confidence intervals for low values. The way we solve
  # it is to loop through all the values of the counter and use a logical test
  # for each one and then bind all the rows together.
  #
  # If the user wants proportions relative to the total population (as opposed
  # to proportions relative to the strata, then we will take survey mean of
  # both of the stratifier and the counter variable, otherwise, we group by the
  # stratifier (if the user specified) and then count by the counter.
  #
  # Once we have this data frame, we will join it with the original result and
  # then make it pretty and/or wide.
  # make sure the survey is ungrouped
  xx <- srvyr::ungroup(x)
  # get the column with all the values of the counter
  ycod <- dplyr::pull(y, !!cod)
  codl <- levels(ycod)
  if (!null_strata && proptotal) {
    # Calculate the survey proportion for both the stratifier and counter
    # @param xx a tbl_svy object
    # @param .x a single character value matching those found in the cod column
    # @param .y a single character value matching those found in the st column
    # @param cod a symbol specifying the column for the counter
    # @param st a symbol specifying the column for the stratifier
    # @return a data frame with five columns, the stratifier, the counter,
    # proportion, lower, and upper.
    s_prop_strat <- function(xx, .x, .y, cod, st) {
      st <- rlang::enquo(st)
      cod <- rlang::enquo(cod)
      res <- srvyr::summarise(xx,
        proportion = srvyr::survey_mean(!!cod == .x & !!st == .y,
          proportion = TRUE,
          vartype = "ci"
        )
      )
      res <- dplyr::bind_cols(!!cod := .x, res, .name_repair = "minimal")
      dplyr::bind_cols(!!st := .y, res, .name_repair = "minimal")
    }
  } else {
    s_prop <- function(xx, .x, cod) {
      cod <- rlang::enquo(cod)
      res <- srvyr::summarise(xx,
        proportion = srvyr::survey_mean(!!cod == .x,
          proportion = TRUE,
          vartype = "ci"
        )
      )
      dplyr::bind_cols(!!cod := rep(.x, nrow(res)), res, .name_repair = "minimal")
    }
  }

  if (!null_strata) {
    # get the column with all the unique values of the stratifier
    yst <- dplyr::pull(y, !!st)
    stl <- levels(yst)
    if (proptotal) {
      # map both the counter and stratifier to sprop
      props <- purrr::map2_dfr(ycod, yst, ~ s_prop_strat(xx, .x, .y, !!cod, !!st))
    } else {
      # group by the stratifier and then map the counter
      xx <- srvyr::group_by(xx, !!st, .drop = FALSE)
      g <- unique(ycod)
      props <- purrr::map_dfr(g, ~ s_prop(xx, .x, !!cod))
    }
    # Make sure that the resulting columns are factors
    props <- dplyr::mutate(props, !!cod := forcats::fct_relevel(!!cod, codl))
    props <- dplyr::mutate(props, !!st := forcats::fct_relevel(!!st, stl))
  } else {
    # no stratifier, just map the counter to sprop and make sure it's a factor
    xx <- srvyr::ungroup(x)
    v <- as.character(y[[1]])
    props <- purrr::map_dfr(ycod, ~ s_prop(xx, .x, !!cod))
    props <- dplyr::mutate(props, !!cod := forcats::fct_relevel(!!cod, codl))
  }

  # Join the data together
  y <- y[!colnames(y) %in% "n_se"]
  join_by <- if (null_strata) names(y)[[1]] else names(y)[1:2]
  y <- dplyr::mutate(y, !!cod := forcats::fct_relevel(!!cod, codl))
  y <- dplyr::left_join(y, props, by = join_by)

  if (coltotals) {
    if (null_strata) {
      tot <- data.frame(n = sum(y$n, na.rm = TRUE))
    } else {
      # group by stratifier
      y <- dplyr::group_by(y, !!st, .drop = FALSE)
      # tally up the Ns
      tot <- dplyr::tally(y, !!rlang::sym("n"), name = "n")
      # bind to the long data frame
      y <- dplyr::ungroup(y)
    }
    suppressMessages(y <- dplyr::bind_rows(y, tot))

    # replace any NAs in the cause of death with "Total"
    y <- dplyr::mutate(y, !!cod := forcats::fct_explicit_na(!!cod, "Total"))
  }

  if (rowtotals && !null_strata) {
    # group by cause of death
    y <- dplyr::group_by(y, !!cod, .drop = FALSE)
    # tally up the Ns
    tot <- dplyr::tally(y, !!rlang::sym("n"), name = "n")
    # bind to the long data frame
    y <- dplyr::ungroup(y)
    suppressMessages(y <- dplyr::bind_rows(y, tot))
    # replace any NAs in the stratifier with "Total"
    y <- dplyr::mutate(y, !!st := forcats::fct_explicit_na(!!st, "Total"))
  }

  if (wide && !null_strata) {
    y <- widen_tabulation(y, !!cod, !!st, pretty = pretty, digits = digits)
  } else if (pretty) {
    y <- prettify_tabulation(y, digits = digits)
  }

  y$"Total deff" <- NULL
  y$"Total ci" <- NULL

  return(y)
}


