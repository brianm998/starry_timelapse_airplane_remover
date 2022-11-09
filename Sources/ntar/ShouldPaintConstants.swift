import Foundation

// do not edit this file by hand, it was generated by ./outlier_analysis.pl
// from 6882 airplane outlier group records
// and 4446 airplane outlier group records

// OAS == Outlier Analysis Score

// keys over lines is the number of unique line counts over the number of lines
// in the hough transform.  Lines tend towards fewer unique line counts.
// There cannot be more keys than lines so this number is betwen 0 and 1
let OAS_AIRPLANE_KEYS_OVER_LINES_AVG = 0.0454918527758866
let OAS_NON_AIRPLANE_KEYS_OVER_LINES_AVG = 0.127064383162395

// the mid value is the index of the line in the sorted list that has the
// same value as the average of the highest line count and lowest line count
// the closer this is to the start, the more likely this is a line.
// each index is divided by the total number of lines so this number is between 0 and 1
let OAS_AIRPLANE_CENTER_LINE_COUNT_POSITION_AVG = 0.0177131601425053
let OAS_NON_AIRPLANE_CENTER_LINE_COUNT_POSITION_AVG = 0.529693555417884

// the average size for each group type.  Larger is more likely to be an airplane streak
// value in in pixels
let OAS_AIRPLANE_GROUP_SIZE_AVG = 803.661871548968
let OAS_NON_AIRPLANE_GROUP_SIZE_AVG = 388.132028789924

// Average fill amount for each group type.  The fill amount is the amount
// of the outlier group's bounding box which is filled by the outlier.
// A fully filled in box is a retangle.  Values between 0 and 1.
let OAS_AIRPLANE_FILL_AMOUNT_AVG = 0.084397936347982
let OAS_NON_AIRPLANE_FILL_AMOUNT_AVG = 0.43954400441806

// the average aspect ratio for each group type.  average group width/height.
let OAS_AIRPLANE_ASPECT_RATIO_AVG = 2.18592931309841
let OAS_NON_AIRPLANE_ASPECT_RATIO_AVG = 1.63730079138503

let OAS_AIRPLANES_KEYS_OVER_LINES_HISTOGRAM = [
    0.00411522633744856,
    0.0473251028806584,
    0.0493827160493827,
    0.0740740740740741,
    0.137860082304527,
    0.160493827160494,
    0.310699588477366,
    0.582304526748971,
    0.734567901234568,
    0.880658436213992,
    0.888888888888889,
    1,
    0.746913580246914,
    0.526748971193416,
    0.506172839506173,
    0.48559670781893,
    0.462962962962963,
    0.44238683127572,
    0.57201646090535,
    0.526748971193416,
    0.491769547325103,
    0.539094650205761,
    0.467078189300412,
    0.421810699588477,
    0.302469135802469,
    0.201646090534979,
    0.207818930041152,
    0.164609053497942,
    0.141975308641975,
    0.150205761316872,
    0.106995884773663,
    0.104938271604938,
    0.0864197530864197,
    0.0967078189300412,
    0.11522633744856,
    0.10082304526749,
    0.0843621399176955,
    0.0720164609053498,
    0.0740740740740741,
    0.0905349794238683,
    0.065843621399177,
    0.0534979423868313,
    0.0452674897119342,
    0.0473251028806584,
    0.037037037037037,
    0.0390946502057613,
    0.037037037037037,
    0.0308641975308642,
    0.0432098765432099,
    0.0452674897119342,
    0.0534979423868313,
    0.0267489711934156,
    0.0411522633744856,
    0.0452674897119342,
    0.0267489711934156,
    0.0164609053497942,
    0.0246913580246914,
    0.0246913580246914,
    0.0246913580246914,
    0.0226337448559671,
    0.0164609053497942,
    0.01440329218107,
    0.0164609053497942,
    0.0123456790123457,
    0.01440329218107,
    0.0123456790123457,
    0.00205761316872428,
    0.0205761316872428,
    0.0123456790123457,
    0.0102880658436214,
    0.00617283950617284,
    0.0164609053497942,
    0.00823045267489712,
    0.00617283950617284,
    0.0102880658436214,
    0.00823045267489712,
    0.00823045267489712,
    0.00411522633744856,
    0.0102880658436214,
    0.00411522633744856,
    0,
    0,
    0.0102880658436214,
    0,
    0,
    0.00205761316872428,
    0.00617283950617284,
    0.00205761316872428,
    0.00205761316872428,
    0,
    0,
    0,
    0.00205761316872428,
    0,
    0.00411522633744856,
    0.00205761316872428,
    0,
    0,
    0,
    0.00411522633744856
]

let OAS_AIRPLANES_MIN_KEYS_OVER_LINES: Double = 0.0042747221430607
let OAS_AIRPLANES_MAX_KEYS_OVER_LINES: Double = 0.219512195121951
let OAS_AIRPLANES_KEYS_OVER_LINES_STEP_SIZE: Double = 0.0021523747297889

let OAS_NON_AIRPLANES_KEYS_OVER_LINES_HISTOGRAM = [
    0.00584795321637427,
    0,
    0,
    0,
    0.00584795321637427,
    0,
    0.0116959064327485,
    0,
    0,
    0,
    0,
    0.00584795321637427,
    0.00584795321637427,
    0.0116959064327485,
    0.0116959064327485,
    0.0175438596491228,
    0.0175438596491228,
    0.0116959064327485,
    0.0233918128654971,
    0.0526315789473684,
    0.0350877192982456,
    0.0467836257309941,
    0.0584795321637427,
    0.064327485380117,
    0.0760233918128655,
    0.0935672514619883,
    0.0994152046783626,
    0.0935672514619883,
    0.12280701754386,
    0.140350877192982,
    0.175438596491228,
    0.192982456140351,
    0.239766081871345,
    0.263157894736842,
    0.327485380116959,
    0.421052631578947,
    0.409356725146199,
    0.380116959064327,
    0.526315789473684,
    0.508771929824561,
    0.678362573099415,
    0.672514619883041,
    0.719298245614035,
    0.654970760233918,
    0.754385964912281,
    0.783625730994152,
    0.736842105263158,
    0.789473684210526,
    0.713450292397661,
    0.783625730994152,
    0.625730994152047,
    0.83625730994152,
    1,
    0.701754385964912,
    0.795321637426901,
    0.795321637426901,
    0.748538011695906,
    0.678362573099415,
    0.695906432748538,
    0.596491228070175,
    0.619883040935672,
    0.532163742690059,
    0.596491228070175,
    0.543859649122807,
    0.497076023391813,
    0.333333333333333,
    0.286549707602339,
    0.339181286549708,
    0.374269005847953,
    0.327485380116959,
    0.321637426900585,
    0.169590643274854,
    0.245614035087719,
    0.152046783625731,
    0.198830409356725,
    0.204678362573099,
    0.146198830409357,
    0.128654970760234,
    0.0994152046783626,
    0.12280701754386,
    0.116959064327485,
    0.064327485380117,
    0.0584795321637427,
    0.0292397660818713,
    0.0584795321637427,
    0.0116959064327485,
    0.0350877192982456,
    0.0292397660818713,
    0.0233918128654971,
    0.0350877192982456,
    0.0292397660818713,
    0.0233918128654971,
    0.00584795321637427,
    0,
    0,
    0.00584795321637427,
    0.00584795321637427,
    0.00584795321637427,
    0,
    0
]

let OAS_NON_AIRPLANES_MIN_KEYS_OVER_LINES: Double = 0.0184928921876966
let OAS_NON_AIRPLANES_MAX_KEYS_OVER_LINES: Double = 0.227272727272727
let OAS_NON_AIRPLANES_KEYS_OVER_LINES_STEP_SIZE: Double = 0.00208779835085031

let OAS_AIRPLANES_CENTER_LINE_COUNT_POSITION_HISTOGRAM = [
    1,
    0.278861602019738,
    0.150103282074822,
    0.0424604085379848,
    0.0183612577461556,
    0.0119348175350011,
    0.00642644021115446,
    0.00642644021115446,
    0.00780353454211613,
    0.00481983015836585,
    0.00504934588019279,
    0.00596740876750057,
    0.00436079871471196,
    0.0045903144365389,
    0.00413128299288501,
    0.00183612577461556,
    0.00183612577461556,
    0.00137709433096167,
    0.0025246729400964,
    0.000688547165480835,
    0.00160661005278862,
    0.00160661005278862,
    0.000918062887307781,
    0.000918062887307781,
    0.00114757860913473,
    0.00137709433096167,
    0.00137709433096167,
    0.000918062887307781,
    0,
    0.000229515721826945,
    0.000229515721826945,
    0.00045903144365389,
    0.00045903144365389,
    0.000229515721826945,
    0.00045903144365389,
    0.000688547165480835,
    0.000229515721826945,
    0.00045903144365389,
    0,
    0,
    0.000229515721826945,
    0.000229515721826945,
    0.000229515721826945,
    0,
    0.000229515721826945,
    0,
    0.000229515721826945,
    0.000229515721826945,
    0,
    0,
    0,
    0,
    0,
    0.000229515721826945,
    0,
    0,
    0.000229515721826945,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0.000229515721826945,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0.000229515721826945,
    0,
    0,
    0,
    0.000229515721826945,
    0,
    0.000229515721826945,
    0.000688547165480835,
    0.000229515721826945,
    0,
    0,
    0,
    0,
    0,
    0,
    0.000229515721826945,
    0,
    0,
    0.000918062887307781,
    0.000229515721826945,
    0.000229515721826945,
    0.000229515721826945,
    0,
    0.00045903144365389,
    0,
    0,
    0
]

let OAS_AIRPLANES_MIN_CENTER_LINE_COUNT_POSITION: Double = 7.77222207829218e-05
let OAS_AIRPLANES_MAX_CENTER_LINE_COUNT_POSITION: Double = 0.98989898989899
let OAS_AIRPLANES_CENTER_LINE_COUNT_POSITION_STEP_SIZE: Double = 0.00989821267678207

let OAS_NON_AIRPLANES_CENTER_LINE_COUNT_POSITION_HISTOGRAM = [
    0.201923076923077,
    0.153846153846154,
    0.221153846153846,
    0.105769230769231,
    0.134615384615385,
    0.153846153846154,
    0.230769230769231,
    0.211538461538462,
    0.307692307692308,
    0.230769230769231,
    0.240384615384615,
    0.259615384615385,
    0.211538461538462,
    0.336538461538462,
    0.192307692307692,
    0.25,
    0.365384615384615,
    0.480769230769231,
    0.5,
    0.471153846153846,
    0.471153846153846,
    0.451923076923077,
    0.365384615384615,
    0.442307692307692,
    0.394230769230769,
    0.490384615384615,
    0.5,
    0.596153846153846,
    0.576923076923077,
    0.625,
    0.461538461538462,
    0.471153846153846,
    0.490384615384615,
    0.471153846153846,
    0.5,
    0.567307692307692,
    0.519230769230769,
    0.596153846153846,
    0.423076923076923,
    0.5,
    0.461538461538462,
    0.538461538461538,
    0.480769230769231,
    0.596153846153846,
    0.490384615384615,
    0.490384615384615,
    0.576923076923077,
    0.471153846153846,
    0.423076923076923,
    0.528846153846154,
    0.480769230769231,
    0.394230769230769,
    0.317307692307692,
    0.567307692307692,
    0.432692307692308,
    0.384615384615385,
    0.336538461538462,
    0.326923076923077,
    0.471153846153846,
    0.317307692307692,
    0.375,
    0.365384615384615,
    0.278846153846154,
    0.471153846153846,
    0.384615384615385,
    0.346153846153846,
    0.326923076923077,
    0.480769230769231,
    0.307692307692308,
    0.326923076923077,
    0.336538461538462,
    0.259615384615385,
    0.442307692307692,
    0.317307692307692,
    0.317307692307692,
    0.288461538461538,
    0.269230769230769,
    0.288461538461538,
    0.288461538461538,
    0.355769230769231,
    0.375,
    0.221153846153846,
    0.230769230769231,
    0.288461538461538,
    0.394230769230769,
    0.365384615384615,
    0.461538461538462,
    0.259615384615385,
    0.346153846153846,
    0.432692307692308,
    0.461538461538462,
    0.403846153846154,
    0.471153846153846,
    0.519230769230769,
    0.548076923076923,
    0.634615384615385,
    0.615384615384615,
    0.653846153846154,
    0.826923076923077,
    1
]

let OAS_NON_AIRPLANES_MIN_CENTER_LINE_COUNT_POSITION: Double = 0.000503207950685621
let OAS_NON_AIRPLANES_MAX_CENTER_LINE_COUNT_POSITION: Double = 0.994186046511628
let OAS_NON_AIRPLANES_CENTER_LINE_COUNT_POSITION_STEP_SIZE: Double = 0.00993682838560942


let OAS_AIRPLANES_GROUP_SIZE_HISTOGRAM = [
    1,
    0.86188753699441,
    0.21473199605393,
    0.0598487339690891,
    0.0480105228543242,
    0.023018743834265,
    0.00953633673133837,
    0.00559026635975008,
    0.00723446234791187,
    0.00460374876685301,
    0.00394607037158829,
    0.00328839197632358,
    0.00328839197632358,
    0.00131535679052943,
    0.00131535679052943,
    0.000986517592897073,
    0.000657678395264716,
    0.00164419598816179,
    0.000328839197632358,
    0.000328839197632358,
    0.00131535679052943,
    0.000986517592897073,
    0,
    0.000328839197632358,
    0.000986517592897073,
    0.000657678395264716,
    0.00131535679052943,
    0,
    0,
    0,
    0.000657678395264716,
    0.000328839197632358,
    0,
    0.000657678395264716,
    0,
    0.000328839197632358,
    0.000328839197632358,
    0,
    0.000657678395264716,
    0.000657678395264716,
    0,
    0,
    0,
    0,
    0,
    0.000328839197632358,
    0.000657678395264716,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0.000328839197632358,
    0,
    0,
    0,
    0,
    0.000328839197632358,
    0,
    0,
    0.000328839197632358,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0
]

let OAS_AIRPLANES_MIN_GROUP_SIZE: Double = 151
let OAS_AIRPLANES_MAX_GROUP_SIZE: Double = 41886
let OAS_AIRPLANES_GROUP_SIZE_STEP_SIZE: Double = 417.35

let OAS_NON_AIRPLANES_GROUP_SIZE_HISTOGRAM = [
    1,
    0.00833719314497453,
    0.00509495136637332,
    0.0016211208893006,
    0.00277906438165818,
    0.00208429828624363,
    0.000926354793886058,
    0.000926354793886058,
    0.000694766095414544,
    0.0016211208893006,
    0.000926354793886058,
    0,
    0.000463177396943029,
    0.000463177396943029,
    0.000231588698471515,
    0.000231588698471515,
    0,
    0.000231588698471515,
    0.000694766095414544,
    0.000926354793886058,
    0,
    0,
    0,
    0,
    0.000231588698471515,
    0.000231588698471515,
    0,
    0.000231588698471515,
    0,
    0,
    0,
    0,
    0,
    0,
    0.000231588698471515,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0.000231588698471515,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0
]

let OAS_NON_AIRPLANES_MIN_GROUP_SIZE: Double = 151
let OAS_NON_AIRPLANES_MAX_GROUP_SIZE: Double = 85357
let OAS_NON_AIRPLANES_GROUP_SIZE_STEP_SIZE: Double = 852.06


let OAS_AIRPLANES_FILL_AMOUNT_HISTOGRAM = [
    0.0290502793296089,
    0.191061452513966,
    0.227932960893855,
    0.475977653631285,
    1,
    0.664804469273743,
    0.939664804469274,
    0.719553072625698,
    0.502793296089385,
    0.319553072625698,
    0.172067039106145,
    0.173184357541899,
    0.240223463687151,
    0.232402234636872,
    0.226815642458101,
    0.164245810055866,
    0.113966480446927,
    0.100558659217877,
    0.0793296089385475,
    0.106145251396648,
    0.0748603351955307,
    0.064804469273743,
    0.0681564245810056,
    0.0636871508379888,
    0.0525139664804469,
    0.0446927374301676,
    0.0569832402234637,
    0.041340782122905,
    0.0424581005586592,
    0.0324022346368715,
    0.0256983240223464,
    0.0201117318435754,
    0.0134078212290503,
    0.017877094972067,
    0.0134078212290503,
    0.0201117318435754,
    0.0167597765363128,
    0.0167597765363128,
    0.0100558659217877,
    0.0189944134078212,
    0.0167597765363128,
    0.0134078212290503,
    0.0156424581005587,
    0.0201117318435754,
    0.0145251396648045,
    0.0100558659217877,
    0.0134078212290503,
    0.00670391061452514,
    0.0111731843575419,
    0.00782122905027933,
    0.0122905027932961,
    0.0100558659217877,
    0.0100558659217877,
    0.00558659217877095,
    0.0100558659217877,
    0.00446927374301676,
    0.00893854748603352,
    0.00670391061452514,
    0.0145251396648045,
    0.00670391061452514,
    0.00670391061452514,
    0.00446927374301676,
    0.00111731843575419,
    0,
    0.00670391061452514,
    0,
    0.00223463687150838,
    0.00111731843575419,
    0.00335195530726257,
    0.00446927374301676,
    0.00558659217877095,
    0.00223463687150838,
    0.00335195530726257,
    0.00111731843575419,
    0.00335195530726257,
    0.00223463687150838,
    0.00111731843575419,
    0,
    0.00111731843575419,
    0.00558659217877095,
    0.00223463687150838,
    0,
    0.00446927374301676,
    0.00335195530726257,
    0.00111731843575419,
    0.00111731843575419,
    0.00111731843575419,
    0.00111731843575419,
    0.00111731843575419,
    0,
    0,
    0,
    0.00223463687150838,
    0,
    0,
    0,
    0,
    0.00111731843575419,
    0,
    0.00111731843575419
]

let OAS_AIRPLANES_MIN_FILL_AMOUNT: Double = 0.00495727635859698
let OAS_AIRPLANES_MAX_FILL_AMOUNT: Double = 0.7
let OAS_AIRPLANES_FILL_AMOUNT_STEP_SIZE: Double = 0.00695042723641403

let OAS_NON_AIRPLANES_FILL_AMOUNT_HISTOGRAM = [
    0.00806451612903226,
    0,
    0,
    0,
    0.00806451612903226,
    0,
    0,
    0,
    0.0161290322580645,
    0.00806451612903226,
    0.00806451612903226,
    0.0483870967741935,
    0.0241935483870968,
    0.0403225806451613,
    0.0645161290322581,
    0.0483870967741935,
    0.0806451612903226,
    0.0725806451612903,
    0.153225806451613,
    0.225806451612903,
    0.233870967741935,
    0.241935483870968,
    0.411290322580645,
    0.306451612903226,
    0.556451612903226,
    0.57258064516129,
    0.580645161290323,
    0.653225806451613,
    0.629032258064516,
    0.629032258064516,
    0.854838709677419,
    0.854838709677419,
    0.951612903225806,
    0.709677419354839,
    0.798387096774194,
    0.766129032258065,
    0.790322580645161,
    0.854838709677419,
    0.838709677419355,
    1,
    0.935483870967742,
    0.806451612903226,
    0.669354838709677,
    0.758064516129032,
    0.895161290322581,
    0.693548387096774,
    0.491935483870968,
    0.709677419354839,
    0.685483870967742,
    0.580645161290323,
    0.604838709677419,
    0.524193548387097,
    0.338709677419355,
    0.443548387096774,
    0.42741935483871,
    0.370967741935484,
    0.306451612903226,
    0.258064516129032,
    0.411290322580645,
    0.467741935483871,
    0.419354838709677,
    0.32258064516129,
    0.25,
    0.201612903225806,
    0.17741935483871,
    0.258064516129032,
    0.387096774193548,
    0.411290322580645,
    0.451612903225806,
    0.508064516129032,
    0.395161290322581,
    0.830645161290323,
    0.725806451612903,
    0.645161290322581,
    0.629032258064516,
    0.467741935483871,
    0.556451612903226,
    0.483870967741935,
    0.411290322580645,
    0.370967741935484,
    0.209677419354839,
    0.354838709677419,
    0.169354838709677,
    0.145161290322581,
    0.201612903225806,
    0.0645161290322581,
    0.0645161290322581,
    0.0887096774193548,
    0.032258064516129,
    0.0564516129032258,
    0.0241935483870968,
    0.0645161290322581,
    0,
    0.0161290322580645,
    0.0161290322580645,
    0.00806451612903226,
    0,
    0,
    0.00806451612903226,
    0
]

let OAS_NON_AIRPLANES_MIN_FILL_AMOUNT: Double = 0.0988749281432208
let OAS_NON_AIRPLANES_MAX_FILL_AMOUNT: Double = 0.798941798941799
let OAS_NON_AIRPLANES_FILL_AMOUNT_STEP_SIZE: Double = 0.00700066870798578


let OAS_AIRPLANES_ASPECT_RATIO_HISTOGRAM = [
    0.223744292237443,
    0.601978691019787,
    0.534246575342466,
    0.572298325722983,
    1,
    0.710045662100457,
    0.520547945205479,
    0.363774733637747,
    0.26027397260274,
    0.127853881278539,
    0.060882800608828,
    0.0327245053272451,
    0.0175038051750381,
    0.0197869101978691,
    0.012937595129376,
    0.0144596651445967,
    0.0144596651445967,
    0.0144596651445967,
    0.00684931506849315,
    0.0121765601217656,
    0.00684931506849315,
    0.0060882800608828,
    0.0091324200913242,
    0.00532724505327245,
    0.0091324200913242,
    0.0045662100456621,
    0.00989345509893455,
    0.00684931506849315,
    0.00380517503805175,
    0.00380517503805175,
    0.0060882800608828,
    0.00380517503805175,
    0.0030441400304414,
    0.0030441400304414,
    0.0015220700152207,
    0.0030441400304414,
    0.00228310502283105,
    0.0030441400304414,
    0.0030441400304414,
    0.00076103500761035,
    0.0030441400304414,
    0.0015220700152207,
    0,
    0.00076103500761035,
    0,
    0.00076103500761035,
    0.00076103500761035,
    0.00076103500761035,
    0.00076103500761035,
    0,
    0,
    0.00076103500761035,
    0,
    0.0015220700152207,
    0.00076103500761035,
    0.00076103500761035,
    0.00076103500761035,
    0.00076103500761035,
    0.0015220700152207,
    0.00076103500761035,
    0.00228310502283105,
    0.00076103500761035,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0.00076103500761035,
    0,
    0,
    0,
    0.00076103500761035,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0
]

let OAS_AIRPLANES_MIN_ASPECT_RATIO: Double = 0.0328947368421053
let OAS_AIRPLANES_MAX_ASPECT_RATIO: Double = 39
let OAS_AIRPLANES_ASPECT_RATIO_STEP_SIZE: Double = 0.389671052631579

let OAS_NON_AIRPLANES_ASPECT_RATIO_HISTOGRAM = [
    0.0324825986078886,
    0.250580046403712,
    0.700696055684455,
    1,
    0.918793503480278,
    0.903712296983759,
    0.387470997679814,
    0.303944315545244,
    0.138051044083527,
    0.248259860788863,
    0.0649651972157773,
    0.0533642691415313,
    0.0394431554524362,
    0.0150812064965197,
    0.0116009280742459,
    0.0127610208816705,
    0.00928074245939675,
    0.00696055684454756,
    0.00928074245939675,
    0.00812064965197216,
    0.00348027842227378,
    0.00464037122969838,
    0.00116009280742459,
    0.00348027842227378,
    0,
    0.00116009280742459,
    0.00232018561484919,
    0.00116009280742459,
    0.00348027842227378,
    0.00116009280742459,
    0.00348027842227378,
    0.00348027842227378,
    0.00116009280742459,
    0.00116009280742459,
    0.00116009280742459,
    0,
    0.00116009280742459,
    0.00232018561484919,
    0,
    0.00116009280742459,
    0,
    0.00116009280742459,
    0.00116009280742459,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0.00116009280742459,
    0,
    0,
    0,
    0.00116009280742459,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0
]

let OAS_NON_AIRPLANES_MIN_ASPECT_RATIO: Double = 0.394736842105263
let OAS_NON_AIRPLANES_MAX_ASPECT_RATIO: Double = 23.6451612903226
let OAS_NON_AIRPLANES_ASPECT_RATIO_STEP_SIZE: Double = 0.232504244482173

let OAS_HISTOGRAM_SIZE = 100

