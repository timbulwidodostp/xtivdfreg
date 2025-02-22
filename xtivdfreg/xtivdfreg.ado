*! version 1.4.2  06feb2024
*! Sebastian Kripfganz, www.kripfganz.de
*! Vasilis Sarafidis, sites.google.com/view/vsarafidis

*==================================================*
****** Defactored IV dynamic panel data estimation ******

*** citation ***

/*	Kripfganz, S., and V. Sarafidis. 2021.
	Instrumental-variable estimation of large-T panel-data models with common factors.
	Stata Journal 21: 659-686.		*/

*** version history at the end of the file ***

program define xtivdfreg, eclass prop(xt)
	version 13.0
	if replay() {
		if !inlist("`e(cmd)'", "xtivdfreg", "spxtivdfreg") {
			error 301
		}
		xtivdfreg_parse_display `0'
		if `"`s(options)'"' != "" {
			di as err `"`s(options)' invalid"'
			exit 198
		}
		if `"`s(cformat)'"' != "" {
			loc diopts			`"cfmt(`s(cformat)')"'
		}
		xtivdfreg_display `0' `diopts'
	}
	else {
		_xt, treq
		syntax varlist(num ts fv) [if] [in] [, SPVARLIST(passthru) SPREGNAMES(passthru) *]
		xtivdfreg_parse_display , `options'
		loc diopts			`"`s(diopts)'"'
		if `"`s(cformat)'"' != "" {
			loc diopts			`"`diopts' cfmt(`s(cformat)')"'
		}
		xtivdfreg_init , `s(options)'
		loc mopt			"`s(mopt)'"
		loc doubledefact	= cond("`s(mg)'" == "", "DOUBLEdefact", "noDOUBLEdefact")
		xtivdfreg_iv `doubledefact' `varlist' `if' `in', mopt(`mopt') `s(mg)' `s(mgi)' `s(options)'
		if "`spvarlist'" != "" {
			xtivdfreg_sp , `spvarlist' `spregnames'
			loc diopts		"`diopts' neq(2)"
		}

		eret loc vcetype	"Robust"
		eret loc marginsok	"XB default"
		eret loc predict	"xtivdfreg_p"
		eret loc estat_cmd	"xtivdfreg_estat"
		eret loc tvar		"`_dta[_TStvar]'"
		eret loc ivar		"`_dta[_TSpanel]'"
		eret loc cmdline 	`"xtivdfreg `0'"'
		eret loc cmd		"xtivdfreg"
		eret hidden loc mopt	"`mopt'"			// undocumented
		xtivdfreg_display , `diopts'
	}
end

program define xtivdfreg_iv, eclass sort
	version 13.0
	gettoken fsyntax 0 : 0
	syntax varlist(num ts fv) [if] [in] , MOPT(name) [	Absorb(varlist num fv)				///
														noCONStant							///
														FACTmax(integer 4)					///
														noEIGratio							///
														STD									///
														FSTAGE								///
														FSTEP								/// historical since version 1.0.2
														MG									///
														MGi(numlist int min=2 max=2)		///
														`fsyntax'							/// DOUBLEdefact noDOUBLEdefact
														*]									// parsed separately: IV()
	loc fv				= ("`s(fvops)'" == "true")
	if `fv' {
		fvexpand `varlist'
		loc varlist			"`r(varlist)'"
	}
	marksample touse
	gettoken depvar indepvars : varlist
	if "`indepvars'" == "" & "`constant'" != "" {
		error 102
	}
	if `fv' {
		_fv_check_depvar `depvar'
	}
	_rmdcoll `depvar' `indepvars', `constant'
	loc indepvars		"`r(varlist)'"
	loc regnames		"`indepvars'"
	if "`constant'" != "" {
		mata: xtivdfreg_init_cons(`mopt', "off")		// constant term
	}
	else {
		loc regnames		"`regnames' _cons"
	}
	if "`mg'" != "" {
		loc id				"`_dta[_TSpanel]'"
		if !`: list id in absorb' & "`constant'" == "" {
			di as err "option absorb() or noconstant required with option mg"
			exit 198
		}
		if "`mgi'" != "" {
			gettoken mg_id mgi : mgi
			mata: xtivdfreg_init_mg(`mopt', "on", `mgi')
		}
		else {
			mata: xtivdfreg_init_mg(`mopt', "on")
		}
		loc fstage			"fstage"
		if "`doubledefact'" == "" {
			loc doubledefact	"doubledefact"
		}
	}
	if "`fstep'" != "" {
		loc fstage			"fstage"
	}
	if "`fstage'" != "" {
		mata: xtivdfreg_init_stages(`mopt', 1)
	}

	*--------------------------------------------------*
	*** syntax parsing of options for instruments ***
	if `factmax' < 0 {
		di as err "option factmax() incorrectly specified -- outside of allowed range"
		exit 125
	}
	mata: xtivdfreg_init_factmax(`mopt', `factmax')
	if "`eigratio'" != "" {
		mata: xtivdfreg_init_eigratio(`mopt', "off")
	}
	loc standardize		= ("`std'" != "")
	loc ivnum			= 0
	loc ivset			= 0
	while `"`options'"' != "" {
		loc ++ivset
		xtivdfreg_parse_options , factmax(`factmax') `eigratio' `std' `doubledefact' `options'
		forv l = 0 / `s(lags)' {
			loc ++ivnum
			loc ivset`ivnum'	= `ivset'
			loc ivvars`ivnum'	"`s(ivvars`l')'"
			loc factvars`ivnum'	"`s(factvars`l')'"
			loc factmax`ivnum'	= `s(factmax)'
			loc eigratio`ivnum'	"`s(eigratio)'"
			loc double`ivnum'	= (`l' == 0 & "`s(doubledefact)'" == "on")
			loc std`ivnum'		= ("`s(std)'" == "on")
			loc ivnames`ivnum'	"`s(ivvarnames)'"
			markout `touse' `ivvars`ivnum'' `factvars`ivnum''
			if !`standardize' & `std`ivnum'' {
				loc standardize		= 1
			}
		}
		loc options			`"`s(options)'"'
	}
	cap xtdes if `touse'
	if _rc == 459 | r(N) == 0 {
		error 2000
	}
	if `factmax' >= r(min) {
		error 2001
	}

	*--------------------------------------------------*
	*** absorption of fixed effects ***
	tempvar depvar_a
	if "`absorb'" == "" {
	    sum `depvar' if `touse', mean
		qui gen double `depvar_a' = `depvar' - r(mean) if `touse'
		if "`indepvars'" != "" {
			forv j = 1 / `: word count `indepvars'' {
				tempvar indepvar`j'_a
				loc var				: word `j' of `indepvars'
				sum `var' if `touse', mean
				qui gen double `indepvar`j'_a' = `var' - r(mean) if `touse'
				loc indepvars_a		"`indepvars_a' `indepvar`j'_a'"
			}
		}
		mata: xtivdfreg_init_touse(`mopt', "`touse'")				// marker variable
		mata: xtivdfreg_init_by(`mopt', "`_dta[_TSpanel]'")		// panel identifier
		mata: xtivdfreg_init_time(`mopt', "`_dta[_TStvar]'")		// time identifier
		mata: xtivdfreg_init_depvar(`mopt', "`depvar_a'", "`depvar'")					// (demeaned) dependent variable
		mata: xtivdfreg_init_indepvars(`mopt', "`indepvars_a'", "`indepvars'")		// (demeaned) independent variables
		forv k = 1 / `ivnum' {
			forv j = 1 / `: word count `ivvars`k''' {
				tempvar ivvar`k'_`j'_a
				loc var				: word `j' of `ivvars`k''
				sum `var' if `touse', mean
				qui gen double `ivvar`k'_`j'_a' = `var' - r(mean) if `touse'
				loc ivvars`k'_a		"`ivvars`k'_a' `ivvar`k'_`j'_a'"
			}
			forv j = 1 / `: word count `factvars`k''' {
				tempvar factvar`k'_`j'_a
				loc var				: word `j' of `factvars`k''
				sum `var' if `touse', mean
				qui gen double `factvar`k'_`j'_a' = `var' - r(mean) if `touse'
				loc factvars`k'_a		"`factvars`k'_a' `factvar`k'_`j'_a'"
			}
			mata: xtivdfreg_init_ivvars(`mopt', `k', "`ivvars`k'_a'")		// demeaned instrumental variables
			if !`std`k'' {
				mata: xtivdfreg_init_ivvars_factvars(`mopt', `k', "`factvars`k'_a'")		// demeaned defactoring variables
			}
			mata: xtivdfreg_init_ivvars_factmax(`mopt', `k', `factmax`k'')
			mata: xtivdfreg_init_ivvars_eigratio(`mopt', `k', "`eigratio`k''")
			mata: xtivdfreg_init_ivvars_group(`mopt', `k', `ivset`k'')
			if `double`k'' {
				loc factnames		"`factnames' `ivvars`k''"
				loc factvars		"`factvars' `ivvars`k'_a'"
			}
		}
	}
	else {
		cap {
			which reghdfe
			which ftools
		}
		if _rc {
			di as err "option absorb() requires further community-contributed packages:"
			di as err "  type {stata ssc install reghdfe} to install {bf:reghdfe}"
			di as err "  type {stata ssc install ftools} to install {bf:ftools}"
			exit 199
		}
		_rmcoll i.(`absorb')
		if "`indepvars'" != "" {
			forv j = 1 / `: word count `indepvars'' {
				tempvar indepvar`j'_a
				loc indepvars_a		"`indepvars_a' `indepvar`j'_a'"
			}
		}
// 		cap mata: xtivdfreg_hdfe = fixed_effects("`absorb'", "`touse'", "", "", 1, -1)
// 		if _rc {
// 			di as err "{bf:reghdfe} Mata library not found:"
// 			di as err "  type {stata reghdfe, check} to compile the library"
// 			exit 3499
// 		}
		cap include "reghdfe.mata", adopath
		cap {
			mata: xtivdfreg_hdfe = FixedEffects()
			mata: xtivdfreg_hdfe.absvars = "`absorb'"
			mata: xtivdfreg_hdfe.tousevar = "`touse'"
			mata: xtivdfreg_hdfe.init()
			mata: xtivdfreg_hdfe.partial_out("`depvar' `indepvars'", 1, 0)
			mata: st_store(xtivdfreg_hdfe.sample, st_addvar("double", tokens("`depvar_a' `indepvars_a'")), xtivdfreg_hdfe.solution.data)
		}
		if _rc {
			di as err "option absorb() requires reghdfe version 6.12.3 or higher and ftools version 2.49.1 or higher:"
			di as err "  type {stata adoupdate reghdfe, update} to update {bf:reghdfe} to its latest version"
			di as err "  type {stata adoupdate ftools, update} to update {bf:ftools} to its latest version"
			exit 3499
		}
// 		mata: xtivdfreg_hdfe_var = xtivdfreg_hdfe.partial_out("`depvar' `indepvars'")
// 		mata: st_store(xtivdfreg_hdfe.sample, st_addvar("double", tokens("`depvar_a' `indepvars_a'")), xtivdfreg_hdfe_var)
		markout `touse' `depvar_a'
		mata: xtivdfreg_init_touse(`mopt', "`touse'")				// marker variable
		mata: xtivdfreg_init_by(`mopt', "`_dta[_TSpanel]'")		// panel identifier
		mata: xtivdfreg_init_time(`mopt', "`_dta[_TStvar]'")		// time identifier
		mata: xtivdfreg_init_depvar(`mopt', "`depvar_a'", "`depvar'")					// (demeaned) dependent variable
		mata: xtivdfreg_init_indepvars(`mopt', "`indepvars_a'", "`indepvars'")		// (demeaned) independent variables
		forv k = 1 / `ivnum' {
			forv j = 1 / `: word count `ivvars`k''' {
				tempvar ivvar`k'_`j'_a
				loc ivvars`k'_a		"`ivvars`k'_a' `ivvar`k'_`j'_a'"
			}
			cap {
				mata: xtivdfreg_hdfe.partial_out("`ivvars`k''", 0, 0)
				mata: st_store(xtivdfreg_hdfe.sample, st_addvar("double", tokens("`ivvars`k'_a'")), xtivdfreg_hdfe.solution.data)
			}
			if _rc {
				di as err "option absorb() requires reghdfe version 6.12.3 or higher and ftools version 2.49.1 or higher:"
				di as err "  type {stata adoupdate reghdfe, update} to update {bf:reghdfe} to its latest version"
				di as err "  type {stata adoupdate ftools, update} to update {bf:ftools} to its latest version"
				exit 3499
			}
// 			mata: xtivdfreg_hdfe_var = xtivdfreg_hdfe.partial_out("`ivvars`k''")
// 			mata: st_store(xtivdfreg_hdfe.sample, st_addvar("double", tokens("`ivvars`k'_a'")), xtivdfreg_hdfe_var)
			forv j = 1 / `: word count `factvars`k''' {
				tempvar factvar`k'_`j'_a
				loc factvars`k'_a	"`factvars`k'_a' `factvar`k'_`j'_a'"
			}
			cap {
				mata: xtivdfreg_hdfe.partial_out("`factvars`k''", 0, 0)
				mata: st_store(xtivdfreg_hdfe.sample, st_addvar("double", tokens("`factvars`k'_a'")), xtivdfreg_hdfe.solution.data)
			}
			if _rc {
				di as err "option absorb() requires reghdfe version 6.12.3 or higher and ftools version 2.49.1 or higher:"
				di as err "  type {stata adoupdate reghdfe, update} to update {bf:reghdfe} to its latest version"
				di as err "  type {stata adoupdate ftools, update} to update {bf:ftools} to its latest version"
				exit 3499
			}
// 			mata: xtivdfreg_hdfe_var = xtivdfreg_hdfe.partial_out("`factvars`k''")
// 			mata: st_store(xtivdfreg_hdfe.sample, st_addvar("double", tokens("`factvars`k'_a'")), xtivdfreg_hdfe_var)
			mata: xtivdfreg_init_ivvars(`mopt', `k', "`ivvars`k'_a'")		// demeaned instrumental variables
			if !`std`k'' {
				mata: xtivdfreg_init_ivvars_factvars(`mopt', `k', "`factvars`k'_a'")		// demeaned defactoring variables
			}
			mata: xtivdfreg_init_ivvars_factmax(`mopt', `k', `factmax`k'')
			mata: xtivdfreg_init_ivvars_eigratio(`mopt', `k', "`eigratio`k''")
			mata: xtivdfreg_init_ivvars_group(`mopt', `k', `ivset`k'')
			if `double`k'' {
				loc factnames		"`factnames' `factvars`k''"
				loc factvars		"`factvars' `factvars`k'_a'"
			}
		}
// 		mata: mata drop xtivdfreg_hdfe xtivdfreg_hdfe_var
		mata: mata drop xtivdfreg_hdfe
	}
	if "`factvars'" != "" {
		mata: xtivdfreg_init_factvars(`mopt', "`factvars'")
	}

	*--------------------------------------------------*
	*** standardization ***
	if `standardize' {
		sort `_dta[_TStvar]' `_dta[_TSpanel]'
		forv k = 1 / `ivnum' {
			if `std`k'' {
				foreach var in `factvars`k'_a' {
					tempname std`var'
					cap by `_dta[_TStvar]': egen double `std`var'' = std(`var') if `touse'
					if _rc == 190 {
						di as err "option std requires Stata 16.1 (with latest updates) or higher"
						exit 199
					}
					loc stdvars`k'		"`stdvars`k'' `std`var''"
					if "`std'" != "" & `double`k'' {
						loc stdvars			"`stdvars' `std`var''"
					}
				}
			}
		}
		sort `_dta[_TSpanel]' `_dta[_TStvar]'
		forv k = 1 / `ivnum' {
			if `std`k'' {
				mata: xtivdfreg_init_ivvars_factvars(`mopt', `k', "`stdvars`k''")		// standardized defactoring variables
			}
		}
		if "`stdvars'" != "" {
			mata: xtivdfreg_init_factvars(`mopt', "`stdvars'")
		}
	}

	*--------------------------------------------------*
	*** estimation ***
	di _n as txt "Defactored instrumental variables estimation"
	mata: xtivdfreg(`mopt')

	mata: st_numscalar("r(N)", xtivdfreg_result_N(`mopt'))
	mata: st_numscalar("r(chi2_J)", xtivdfreg_result_overid(`mopt'))
	mata: st_numscalar("r(rank)", xtivdfreg_result_rank(`mopt'))
	mata: st_numscalar("r(zrank)", xtivdfreg_result_zrank(`mopt'))
	mata: st_matrix("r(b)", xtivdfreg_result_coefs(`mopt'))
	mata: st_matrix("r(V)", xtivdfreg_result_V(`mopt'))
	loc N				= r(N)
	loc chi2_J			= r(chi2_J)
	loc rank			= r(rank)
	loc zrank			= r(zrank)
	tempname b V factnum
	mat `b'				= r(b)
	mat `V'				= r(V)
	mat coln `b'		= `regnames'
	mat rown `V'		= `regnames'
	mat coln `V'		= `regnames'
	if "`mg'" != "" {
		qui levelsof `_dta[_TSpanel]' if `touse'
		loc groups			"`r(levels)'"
		tempname b_mg se_mg
		mata: st_matrix("r(b_mg)", xtivdfreg_result_coefs(`mopt', ., 0))
		mata: st_matrix("r(se_mg)", sqrt(xtivdfreg_result_V(`mopt', ., 0)))
		mat `b_mg'			= r(b_mg)
		mat `se_mg'			= r(se_mg)
		mat rown `b_mg'		= `groups'
		mat coln `b_mg'		= `regnames'
		mat rown `se_mg'	= `groups'
		mat coln `se_mg'	= `regnames'
	}

	if "`factvars'" != "" {
		mata: st_numscalar("r(fact1)", xtivdfreg_result_factnum(`mopt', 1))
		loc fact1double		= r(fact1)
		loc fact1			= `fact1double'
	}
	else {
		loc fact1			= .
	}
	loc fact1equal		= 1
	if `ivnum' {
		forv k = 1 / `ivnum' {
			if !`: list ivset`k' in ivsets' {
				loc ivsets			"`ivsets' `ivset`k''"
				mata: st_numscalar("r(fact1)", xtivdfreg_result_factnum(`mopt', 1, `k'))
				mat `factnum'		= (nullmat(`factnum'), r(fact1))
				if `fact1equal' {
					if `fact1' < . {
						loc fact1equal		= (r(fact1) == `fact1')
					}
					else {
						loc fact1			= r(fact1)
					}
				}
				if "`ivnames`k''" != "" {
					loc ivlist`ivset`k'' "`ivnames`k''"
					if "`ivvars`k''" == "`factvars`k''" {
						loc factlist`ivset`k'' "`ivnames`k''"
					}
					else {
						loc factlist`ivset`k'' "`factvars`k''"
					}
				}
				else {
					loc ivlist`ivset`k'' "`ivvars`k''"
					loc factlist`ivset`k'' "`factvars`k''"
				}
			}
		}
		if "`factvars'" != "" {
			mat `factnum'		= (`factnum', `fact1double')
			loc ivsets			"`ivsets' ."
		}
		mat coln `factnum'	= `ivsets'
	}

	*--------------------------------------------------*
	*** current estimation results ***
	if `fv' {
		loc fvopt			"buildfv"
	}
	eret post `b' `V', dep(`depvar') o(`N') e(`touse') `fvopt' findomitted
	eret sca df_m		= `rank'
	mata: st_numscalar("e(N_g)", xtivdfreg_result_Ng(`mopt'))
	mata: st_numscalar("e(g_min)", xtivdfreg_result_Tmin(`mopt'))
	eret sca g_avg		= e(N) / e(N_g)
	mata: st_numscalar("e(g_max)", xtivdfreg_result_Tmax(`mopt'))
	if "`fstage'" == "" {
		mata: st_numscalar("e(sigma2u)", xtivdfreg_result_sigma2(`mopt', 1))
		mata: st_numscalar("e(sigma2f)", xtivdfreg_result_sigma2(`mopt', 2))
		eret sca rho		= e(sigma2f) / e(sigma2u)
	}
	if "`mg'" == "" {
		eret sca chi2_J		= `chi2_J'
		eret sca df_J		= `zrank' - `rank'
		eret sca p_J		= chi2tail(`zrank' - `rank', `chi2_J')
	}
	eret sca rank		= `rank' + ("`constant'" == "")
	eret sca zrank		= `zrank'
	if `fact1equal' {
		eret sca fact1		= `fact1'
	}
	if "`fstage'" == "" {
		mata: st_numscalar("e(fact2)", xtivdfreg_result_factnum(`mopt', 2))
		eret loc estimator	"sstage"
	}
	else if "`mg'" == "" {
		eret loc estimator	"fstage"
	}
	else {
		eret loc estimator	"mg"
		eret mat se_mg		= `se_mg'
		eret mat b_mg		= `b_mg'
	}
	if "`mg_id'" != "" {
		eret sca mg_id		= `mg_id'
	}

	*--------------------------------------------------*
	*** hidden estimation results ***					// undocumented
	if `ivnum' {
		foreach k of num `ivsets' {
		    if `k' < . {
				eret hidden loc ivset`k' "`ivlist`k''"
				eret hidden loc factset`k' "`factlist`k''"
			}
			else {
				eret hidden loc doubledefact "`: list retok factnames'"
			}
		}
		if `ivnum' {
			eret hidden mat factnum = `factnum'
		}
	}
end

*==================================================*
**** display of estimation results ****
program define xtivdfreg_display
	version 13.0
	syntax [, noHEader noTABle CFMT(string asis) *]

	if "`header'" == "" {
		di _n as txt "Group variable: " as res abbrev("`e(ivar)'", 12) _col(46) as txt "Number of obs" _col(68) "=" _col(70) as res %9.0f e(N)
		di as txt "Time variable: " as res abbrev("`e(tvar)'", 12) _col(46) as txt "Number of groups" _col(68) "=" _col(70) as res %9.0f e(N_g)
		di _n as txt "Number of instruments  =" as res %7.0f e(zrank) _col(46) as txt "Obs per group" _col(64) "min =" _col(70) as res %9.0g e(g_min)
		di as txt "Number of factors in X =" _c
		if e(fact1) < . {
			di as res %7.0f e(fact1) _col(64) as txt "avg =" _col(70) as res %9.0g e(g_avg)
		}
		else {
			di _col(31) "*" _col(64) as txt "avg =" _col(70) as res %9.0g e(g_avg)
		}
		if "`e(estimator)'" == "sstage" {
			di as txt "Number of factors in u =" as res %7.0f e(fact2) _col(64) as txt "max =" _col(70) as res %9.0g e(g_max)
		}
		else {
			di _col(64) as txt "max =" _col(70) as res %9.0g e(g_max)
		}
		if "`e(estimator)'" == "sstage" {
			di _n as txt "Second-stage estimator (model with homogeneous slope coefficients)"
		}
		else if "`e(estimator)'" == "fstage" {
			di _n as txt "First-stage estimator (model with homogeneous slope coefficients)"
		}
		else if "`e(estimator)'" == "mg" {
			di _n as txt "Mean-group estimator " _c
			if e(mg_id) < . {
				di "for group " as res e(mg_id)
			}
			else {
				di "(model with heterogeneous slope coefficients)"
			}
		}
	}
	if "`table'" == "" {
		if "`e(estimator)'" == "sstage" {
			_coef_table, `options' plus
			loc wc1				= `s(width_col1)' - 1
			loc wc2				= `s(width)' - `s(width_col1)' - 1
			di as txt %`wc1's "sigma_f" " {c |} " as res %10s "`: di `cfmt' sqrt(e(sigma2f))'" as txt "   (std. dev. of factor error component)"
			di as txt %`wc1's "sigma_e" " {c |} " as res %10s "`: di `cfmt' sqrt(e(sigma2u) - e(sigma2f))'" as txt "   (std. dev. of idiosyncratic error component)"
			di as txt %`wc1's "rho" " {c |} " as res %10s "`: di `cfmt' e(rho)'" as txt "   (fraction of variance due to factors)"
			loc ++wc1
			di as txt "{hline `wc1'}{c BT}{hline `wc2'}"
		}
		else {
			_coef_table, `options'
		}
	}
	if "`header'" == "" {
		if "`e(estimator)'" != "mg" {
			di as txt "Hansen test of the overidentifying restrictions" _col(56) "chi2(" as res e(df_J) as txt ")" _col(68) "=" _col(70) as res %9.4f e(chi2_J)
			if e(df_J) {
				di as txt "H0: overidentifying restrictions are valid" _c
			}
			else {
				di as txt "note: coefficients are exactly identified" _c
			}
			di _col(56) as txt "Prob > chi2" _col(68) "=" _col(73) as res %6.4f e(p_J)
		}
		if e(fact1) == . {
			if "`e(estimator)'" != "mg" {
				di ""
			}
			cap conf mat e(factnum)
			if _rc {
				di as txt "* note: no instruments specified"
			}
			else {
				di as txt "* Number of factors in stage 1:"
				loc ivsets			: coln e(factnum)
				loc K				= colsof(e(factnum))
				forv k = 1 / `K' {
					loc ivset			: word `k' of `ivsets'
					di as res %5.0f el(e(factnum), 1, `k') as txt " -> " _c
					loc ivnames			= cond(`ivset' < ., "`e(factset`ivset')'", "`e(doubledefact)' (doubledefact)")
					loc p				= 1
					loc piece			: piece 1 69 of "`ivnames'", nobreak
					while "`piece'" != "" {
						di _col(10) "`piece'"
						loc ++p
						loc piece			: piece `p' 69 of "`ivnames'", nobreak
					}
				}
			}
		}
	}
end

*==================================================*
**** syntax parsing of additional display options ****
program define xtivdfreg_parse_display, sclass
	version 13.0
	sret clear
	syntax , [noHEader noTABle PLus *]
	_get_diopts diopts options, `options'

	sret loc diopts		`"`header' `table' `plus' `diopts'"'
	sret loc options	`"`options'"'
end

*==================================================*
**** syntax parsing of the optimization options ****
program define xtivdfreg_init, sclass
	version 13.0
	sret clear
	loc maxiter			= c(maxiter)
	syntax [, ITERate(integer `maxiter') noDOTs LTOLerance(real 1e-4) MG MGi(numlist int miss max=1) *]

	if `iterate' < 0 {
		di as err "option iterate() incorrectly specified -- outside of allowed range"
		exit 125
	}
	loc mopt			"xtivdfreg_iv"
	mata: `mopt' = xtivdfreg_init()
	mata: xtivdfreg_init_conv_maxiter(`mopt', `iterate')
	if "`dots'" != "" {
		mata: xtivdfreg_init_dots(`mopt', "off")
	}
	mata: xtivdfreg_init_conv_vtol(`mopt', `ltolerance')
	if "`mgi'" != "" {
		if `mgi' < . {
			tempvar id
			egen long `id' = group(`_dta[_TSpanel]')
			sum `id' if `_dta[_TSpanel]' == `mgi', mean
			if r(N) == 0 {
				di as err "option mg() out of range"
				exit 175
			}
			loc mgi				"mgi(`mgi' `r(mean)')"
		}
		else {
			loc mgi				""
		}
		loc mg				"mg"
	}

	sret loc mopt		"`mopt'"
	sret loc mg			"`mg'"
	sret loc mgi		"`mgi'"
	sret loc options	`"`options'"'
end

*==================================================*
**** adjustment for spatial regressors ****
program define xtivdfreg_sp, eclass
	version 13.0
	syntax [, SPVARLIST(varlist num ts) SPREGNAMES(varlist num ts fv)]

	tempname b V
	mat `b'				= e(b)
	mat `V'				= e(V)
	loc regnames		: coln `b'
	foreach spvar of var `spvarlist' {
		gettoken spregname spregnames : spregnames
		loc regnames		: subinstr loc regnames "`spvar'" "", w
		loc regnames		: subinstr loc regnames "o.`spvar'" "", w
		loc regnames		"`regnames' W:`spregname'"
	}
	loc cons			"_cons"
	loc hascons			: list cons in regnames
	loc K				= colsof(`b')
	loc Ksp				: word count `spvarlist'
	if `hascons' {
		if `K' == `Ksp' + 1 {
			mata: st_matrix("`b'", st_matrix("`b'")[1, (`K', `K'-`Ksp'..`K'-1)])
			mata: st_matrix("`V'", st_matrix("`V'")[(`K' \ `K'-`Ksp'::`K'-1), (`K', `K'-`Ksp'..`K'-1)])
		}
		else {
			mata: st_matrix("`b'", st_matrix("`b'")[1, (1..`K'-`Ksp'-1, `K', `K'-`Ksp'..`K'-1)])
			mata: st_matrix("`V'", st_matrix("`V'")[(1::`K'-`Ksp'-1 \ `K' \ `K'-`Ksp'::`K'-1), (1..`K'-`Ksp'-1, `K', `K'-`Ksp'..`K'-1)])
		}
	}
	mat coln `b'		= `regnames'
	mat coln `V'		= `regnames'
	mat rown `V'		= `regnames'
	eret repost b = `b' V = `V', ren
end

*==================================================*
**** syntax parsing of options for instruments ****
program define xtivdfreg_parse_options, sclass
	version 13.0
	sret clear
	syntax , FACTmax(integer) [noEIGratio DOUBLEdefact STD IV(string) *]

	if `"`iv'"' != "" {
		loc eigratio		= cond("`eigratio'" == "", "noEIGratio", "EIGratio")
		loc doubledefact	= cond("`doubledefact'" == "", "DOUBLEdefact", "noDOUBLEdefact")
		loc std				= cond("`std'" == "", "STD", "noSTD")
		xtivdfreg_parse_iv `factmax' `eigratio' `doubledefact' `std' `iv'
	}
	else {
		di as err `"`options' invalid"'
		exit 198
	}

	sret loc options	`"`options'"'
end

*==================================================*
**** syntax parsing for instruments ****
program define xtivdfreg_parse_iv, sclass
	version 13.0
	gettoken factmax 0 : 0
	gettoken esyntax 0 : 0
	gettoken fsyntax 0 : 0
	gettoken ssyntax 0 : 0
	syntax varlist(num ts fv), [FVAR(varlist num ts fv) Lags(integer 0) FACTmax(integer `factmax') `esyntax' `fsyntax' `ssyntax'		///
								VARNames(string)]																						// undocumented

	if `lags' < 0 {
		di as err "option lags() incorrectly specified -- outside of allowed range"
		exit 125
	}
	if `factmax' < 0 {
		di as err "option factmax() incorrectly specified -- outside of allowed range"
		exit 125
	}
	loc eigratio		= cond(("`esyntax'" == "noEIGratio" & "`eigratio'" == "") | ("`esyntax'" == "EIGratio" & "`eigratio'" != ""), "on", "off")
	loc doubledefact	= cond(("`fsyntax'" == "noDOUBLEdefact" & "`doubledefact'" == "") | ("`fsyntax'" == "DOUBLEdefact" & "`doubledefact'" != ""), "on", "off")
	loc std				= cond(("`ssyntax'" == "noSTD" & "`std'" == "") | ("`ssyntax'" == "STD" & "`std'" != ""), "on", "off")
	if "`s(fvops)'" == "true" {
		fvexpand `varlist'
		loc varlist			"`r(varlist)'"
		foreach var in `varlist' {
			forv l = 0 / `lags' {
				loc ivvar`l'		: subinstr loc var "#" "#L`l'.", all
				fvunab ivvar`l' : L`l'.`ivvar`l''
				loc ivvars`l'		"`ivvars`l'' `ivvar`l''"
			}
		}
		if "`fvar'" == "" {
			loc fvar			"`varlist'"
		}
		else {
			fvexpand `fvar'
			loc fvar			"`r(varlist)'"
		}
		foreach var in `fvar' {
			forv l = 0 / `lags' {
				loc factvar`l'		: subinstr loc var "#" "#L`l'.", all
				fvunab factvar`l' : L`l'.`factvar`l''
				loc factvars`l'		"`factvars`l'' `factvar`l''"
			}
		}
	}
	else {
		if "`fvar'" == "" {
			loc fvar			"`varlist'"
		}
		forv l = 0 / `lags' {
			fvunab ivvars`l' : L`l'.(`varlist')
			fvunab factvars`l' : L`l'.(`fvar')
		}
	}

	sret loc ivvarnames	"`varnames'"
	sret loc std		"`std'"
	sret loc doubledefact "`doubledefact'"
	sret loc eigratio	"`eigratio'"
	sret loc factmax	"`factmax'"
	sret loc lags		"`lags'"
	forv l = 0 / `lags' {
		sret loc ivvars`l'	"`: list retok ivvars`l''"
		sret loc factvars`l' "`: list retok factvars`l''"
	}
end

*==================================================*
*** version history ***
* version 1.4.2  06feb2024  option mg now requires either option absorb(panelvar) or noconstant; bug fixed with option mg() in combination with option nodoubledefact
* version 1.4.1  31jan2024  bug fixed with estat impact under Stata versions before Stata 16
* version 1.4.0  30jan2024  option mg() added for group-specific estimates
* version 1.3.7  24jan2024  matrix e(se_mg) returned with option mg
* version 1.3.6  17jan2024  bug fixed due to incompatibility of sortpreserve with reghdfe; matrix e(b_mg) returned with option mg
* version 1.3.5  11sep2023  option absorb() updated for version 6 of reghdfe
* version 1.3.4  13jul2023  bug fixed with option std in combination with option doubledefact
* version 1.3.3  11jul2023  stability condition for long-run impacts in estat impact corrected
* version 1.3.2  26may2025  bug fixed with too few time periods; stability condition for long-run impacts in estat impact corrected
* version 1.3.1  28feb2023  model stability checks implemented for estat impact; short-run impacts for lagged dependent variable in estat impact suppressed
* version 1.3.0  26feb2023  options tlags() and sptlags() added to spxtivdfreg; options lr and post added to estat impact
* version 1.2.5  03jan2023  varlist and option constant added to estat impact; Delta method standard errors implemented for estat impact
* version 1.2.4  22dec2022  postestimation command estat impact added for spxtivdfreg
* version 1.2.3  17dec2022  postestimation command predict added for spxtivdfreg
* version 1.2.2  04dec2022  option std added; suboption splags added to option iv() in spxtivdfreg; bug with option absorb() fixed
* version 1.2.1  28nov2022  various bugs fixed with spxtivdfreg; option spiv() integrated in option iv()
* version 1.2.0  21nov2022  command spxtivdfreg added
* version 1.1.0  01sep2022  speed improvements; bug fixed with large data sets
* version 1.0.3  12feb2021  Stata Journal version; suboption fvar() for option iv() added
* version 1.0.2  24jan2021  option fstep replaced by option fstage
* version 1.0.1  10oct2020  bug fixed with interaction terms as instruments
* version 1.0.0  06aug2020  available online at www.kripfganz.de
* version 0.3.1  04aug2020
* version 0.3.0  03aug2020
* version 0.2.3  24jul2020
* version 0.2.2  23jul2020
* version 0.2.1  22jul2020
* version 0.2.0  19jul2020
* version 0.1.1  01jul2020
* version 0.1.0  29jun2020
* version 0.0.3  19jun2020
* version 0.0.2  18jun2020
* version 0.0.1  17jun2020
