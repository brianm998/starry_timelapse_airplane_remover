import XCTest
@testable import StarCore

/// Tests for the cross-frame consistency check on star homographies, and for the parts of
/// `validateMovingStarAlignment` that decide whether to trust a measured set.
///
/// The bug these exist for: on frames 481 and 482 of the 2103 frame
/// `11_30_2024-a9-1-aurora-topaz` sequence, most stars blinked out of the rendered video.
/// The aligner had measured both frames correctly — re-running its matching from the run's
/// own cached keypoints reproduces every other frame's stored matrix exactly, and agrees
/// with phase correlation on the images to within 0.4px — but the gap-fill repair threw
/// those measurements away and substituted a blend of frames 471 and 492, ten frames away
/// on either side of a transient pan-rate excursion.  The substitute was wrong by up to
/// 4.7px at offset ±4, which was enough for the merge's bright-outlier trimming to discard
/// the faint stars: the star energy in the star-aligned merge fell from a steady 0.80-0.82
/// of the original to 0.48, on those two frames and no others in the sequence.
///
/// What let that happen is that every check in `alignmentLooksOk` is internal to one
/// frame's own neighbor set, so it cannot tell a set that is smooth and collectively wrong
/// from one that is right — and on an accelerating pan it flags real measurements, because
/// `deviation` is `‖H−I‖` and that is only linear in frame distance while the rate is
/// constant.  The fixtures below are the actual matrices from that stretch of the run.
final class HomographyReciprocityTests: XCTestCase {

    // MARK: - fixtures

    /// Real homographies from `star_temp_.../homography.db` and, for `measured`, from
    /// re-running `ia_compute_homography`'s sky matching over that run's cached
    /// `keypoints/<frame>.sky.yaml`.  Keyed frame index → offset → row-major 3x3.
    ///
    /// `measured` is what the aligner computed.  `repaired` is what the gap-fill wrote
    /// over frames 481 and 482 instead.
    private enum Incident {
    static let measured: [Int: [Int: [Double]]] = [
      477: [
        -4: [0.997955531261, -0.00409061287415, 6.68272375315,
            0.000606730094906, 0.995212014523, 22.7391128312,
            6.6904050821e-08, -1.22447923804e-06, 1],
        -3: [0.998410828009, -0.00313385263006, 5.15228068456,
            0.000449723586372, 0.996340128798, 17.1218637156,
            4.63231399435e-08, -9.33763254709e-07, 1],
        -2: [0.998895670414, -0.00212826485319, 3.56539323456,
            0.000270805605423, 0.997502000691, 11.5505616247,
            2.79135743109e-08, -6.33070829743e-07, 1],
        -1: [0.999533119942, -0.00100847423955, 1.58703602378,
            0.000162740064826, 0.998830250419, 5.66785936477,
            2.31532625205e-08, -3.02637772398e-07, 1],
        1: [1.00056660678, 0.000957707756926, -1.87558268053,
            -9.4897324685e-05, 1.00120514382, -5.91362685776,
            -5.85833674741e-09, 2.87676032319e-07, 1],
        2: [1.0011221951, 0.00189720894242, -3.80970733199,
            -0.000191009862595, 1.00243088849, -11.7947363541,
            -1.04412933854e-08, 5.85140280919e-07, 1],
        3: [1.00192436181, 0.00294468877068, -6.39642470402,
            -0.000206636985044, 1.00381319002, -17.9576679472,
            1.474015965e-08, 9.03673089626e-07, 1],
        4: [1.00282784277, 0.00405513975028, -9.29715551728,
            -0.000239448269859, 1.00523564189, -23.9598037745,
            4.70299761913e-08, 1.25641857564e-06, 1],
      ],
      478: [
        -4: [0.997851069142, -0.00410655457899, 6.98390600385,
            0.00054916029885, 0.995123690591, 22.9674598387,
            5.2303486619e-08, -1.22767148927e-06, 1],
        -3: [0.998278359639, -0.00312923851739, 5.52578855016,
            0.000381569310143, 0.996257888312, 17.3848433603,
            2.88793162387e-08, -9.38163692728e-07, 1],
        -2: [0.998952776943, -0.00199753068082, 3.44458905775,
            0.000282602512514, 0.997624038591, 11.4074113308,
            2.62798772611e-08, -6.00548123793e-07, 1],
        -1: [0.999439901905, -0.000940990429975, 1.82989442809,
            9.09090264665e-05, 0.998807335935, 5.9032684671,
            5.15192585811e-09, -2.8456313333e-07, 1],
        1: [1.00061099899, 0.000977854502113, -2.08100569101,
            -8.81661733652e-05, 1.00127111335, -5.91507094829,
            9.05167245187e-10, 3.04321464689e-07, 1],
        2: [1.00142973502, 0.00203718222929, -4.68834955016,
            -0.000108385692392, 1.00264924955, -12.0378256358,
            2.72424755685e-08, 6.31734235984e-07, 1],
        3: [1.00210640136, 0.00296587008914, -7.06991742477,
            -0.000117514155245, 1.00391040694, -18.1511838607,
            3.96135670587e-08, 9.29135469288e-07, 1],
        4: [1.00300521768, 0.00390699716703, -10.0170819736,
            -5.57661091997e-05, 1.00529878412, -24.5134006211,
            8.30549252052e-08, 1.24527679091e-06, 1],
      ],
      479: [
        -4: [0.99764701434, -0.00411135133655, 7.63329731727,
            0.000466855326745, 0.995002055981, 23.2503012731,
            2.54975822469e-08, -1.24934920945e-06, 1],
        -3: [0.998305339363, -0.00300426195303, 5.61783364759,
            0.000351963217196, 0.996361308805, 17.3574444686,
            2.27413695528e-08, -9.14189282223e-07, 1],
        -2: [0.998833397658, -0.00191045252566, 3.8884760199,
            0.000181005308746, 0.997550368342, 11.802708843,
            4.68387173641e-09, -5.89711970517e-07, 1],
        -1: [0.999356998508, -0.000976088688741, 2.12793854702,
            8.14845886966e-05, 0.998722599966, 5.92428244989,
            -4.88910377363e-09, -3.07711079683e-07, 1],
        1: [1.00068639521, 0.000985301573717, -2.36274598886,
            -2.19274602838e-05, 1.00130156033, -6.11542529254,
            1.08529118907e-08, 3.06255726018e-07, 1],
        2: [1.00140122675, 0.00191674464484, -4.75084157327,
            -5.63717234235e-05, 1.00258969218, -12.1203676835,
            3.07465742925e-08, 6.06575759546e-07, 1],
        3: [1.00231480193, 0.00291067181271, -7.78680461473,
            1.96497838143e-05, 1.00399910389, -18.5458693645,
            7.48663152599e-08, 9.28929753805e-07, 1],
        4: [1.00318938658, 0.00383098005759, -10.8814830759,
            9.36315027963e-05, 1.00537292796, -24.9635492245,
            1.17152661836e-07, 1.22944695215e-06, 1],
      ],
      480: [
        -4: [0.997530973247, -0.004005954455, 8.08424728542,
            0.000369039660558, 0.994971006386, 23.4885069278,
            -2.91946703639e-09, -1.22274322618e-06, 1],
        -3: [0.998098384913, -0.00292271933977, 6.30735406852,
            0.000209695888218, 0.996220631273, 17.8500497196,
            -1.42521558471e-08, -9.02553199284e-07, 1],
        -2: [0.998583564885, -0.00204933395045, 4.65815952861,
            0.000114968917887, 0.997354344815, 11.9743789938,
            -2.63244008083e-08, -6.34899859504e-07, 1],
        -1: [0.999286245575, -0.000993792762474, 2.38115980321,
            2.28347504983e-05, 0.998671384228, 6.09807921299,
            -1.58929510854e-08, -3.067208355e-07, 1],
        1: [1.00059685218, 0.000756745292126, -1.97426153217,
            -2.60303335857e-05, 1.00113488759, -5.88236493296,
            1.04510673215e-08, 2.68952254072e-07, 1],
        2: [1.00144756225, 0.00169845993851, -4.92017285023,
            2.83959346487e-05, 1.00248038956, -12.2239093314,
            4.76347648787e-08, 5.73077737684e-07, 1],
        3: [1.0024477852, 0.00282236982583, -8.36025712044,
            0.000112047379758, 1.00405872873, -18.7940883866,
            1.00571219151e-07, 9.19280458847e-07, 1],
        4: [1.00328730325, 0.00349910390079, -11.0636018122,
            0.000179388791245, 1.0052437133, -24.9804468932,
            1.48607489632e-07, 1.18272034839e-06, 1],
      ],
      481: [
        -4: [0.997321910227, -0.00389846371177, 8.85962605692,
            0.000218877971883, 0.994912099678, 23.8898419799,
            -3.86735520726e-08, -1.21588712585e-06, 1],
        -3: [0.998143026048, -0.00263651028362, 6.27700847271,
            0.000146742038209, 0.996386159246, 17.8008471884,
            -2.2879474593e-08, -8.6176422727e-07, 1],
        -2: [0.998608414415, -0.00191578161232, 4.7358426685,
            4.81999743058e-05, 0.997416967338, 12.1211076852,
            -3.0206994359e-08, -6.05078604246e-07, 1],
        -1: [0.999446300905, -0.000738698583643, 1.89722881839,
            3.75025014654e-05, 0.998900140608, 5.83083171907,
            -5.53421334683e-09, -2.64135066378e-07, 1],
        1: [1.00108460582, 0.00124756919578, -3.56621832659,
            9.49810393446e-05, 1.00166160319, -6.61618039871,
            5.603939395e-08, 3.78827878451e-07, 1],
        2: [1.0018550002, 0.00208811111833, -6.42977144126,
            0.000147901417928, 1.00298859706, -12.96203989,
            8.66016711065e-08, 6.68935342286e-07, 1],
        3: [1.00260789313, 0.00280854803217, -8.96650609848,
            0.000191501819223, 1.00415787374, -19.0782436697,
            1.24192644794e-07, 9.42262683753e-07, 1],
        4: [1.00386187681, 0.00406102028141, -13.0011596227,
            0.000331558811495, 1.00588413049, -25.946338344,
            2.03756304136e-07, 1.30821926088e-06, 1],
      ],
      482: [
        -4: [0.997043880887, -0.00386248008112, 9.84543037625,
            6.18300023867e-05, 0.994758418252, 24.3255115239,
            -8.26420000045e-08, -1.23405839883e-06, 1],
        -3: [0.997688392036, -0.0029012266143, 7.74490018765,
            -1.66963788035e-05, 0.996007082083, 18.4564408883,
            -7.71852277133e-08, -9.26646324473e-07, 1],
        -2: [0.998454761488, -0.00190057930368, 5.29143109959,
            -3.91903719063e-05, 0.997348409723, 12.35968342,
            -5.20727977551e-08, -6.18460122884e-07, 1],
        -1: [0.999069509605, -0.00100575189592, 3.05254995742,
            -7.0753061354e-05, 0.998548923364, 6.38417483931,
            -4.60270054614e-08, -3.29493896048e-07, 1],
        1: [1.00099708445, 0.000968378223445, -3.25808151875,
            0.000105959163371, 1.00147343476, -6.519741744,
            5.95344734967e-08, 3.15032821954e-07, 1],
        2: [1.00187318131, 0.00188552532321, -6.26330545394,
            0.000152503660431, 1.0028297962, -12.7675538461,
            1.03516670308e-07, 6.23050794455e-07, 1],
        3: [1.00277470088, 0.00275270960125, -9.28999019997,
            0.000244573131027, 1.00422536012, -19.2744263234,
            1.52322858173e-07, 9.2174608577e-07, 1],
        4: [1.00380347275, 0.00368138051143, -12.5752493855,
            0.000354509689758, 1.00571435247, -25.8250306129,
            2.1753350586e-07, 1.24047696447e-06, 1],
      ],
      483: [
        -4: [0.99673567852, -0.0039310586355, 11.0508474101,
            -7.2919579231e-05, 0.994535322939, 24.7483644407,
            -1.26788919728e-07, -1.2510769637e-06, 1],
        -3: [0.997436216987, -0.00283918577628, 8.51662497092,
            -0.000143757110513, 0.995914576552, 18.8191403825,
            -1.19557357258e-07, -9.14552693094e-07, 1],
        -2: [0.998009974408, -0.00220790798692, 6.74094840164,
            -0.000157970562429, 0.996890013723, 12.9942494562,
            -1.00840965951e-07, -6.96444557262e-07, 1],
        -1: [0.998979969611, -0.000978744084228, 3.29262470358,
            -0.000110150528943, 0.998519266547, 6.51410336186,
            -6.22809310929e-08, -3.2023092501e-07, 1],
        1: [1.00096438879, 0.000922137427241, -3.11355316545,
            9.04957146376e-05, 1.00140461137, -6.39136641417,
            5.68333209503e-08, 3.09399516016e-07, 1],
        2: [1.00185887627, 0.0018536424674, -6.2133372481,
            0.000174051830879, 1.00283601162, -12.8894997957,
            1.01649999534e-07, 6.17958106157e-07, 1],
        3: [1.0028288721, 0.00277687931096, -9.47856133429,
            0.000273072059029, 1.00425848701, -19.3816897357,
            1.5864615807e-07, 9.27862812842e-07, 1],
        4: [1.00366093977, 0.00369074250166, -12.4534263745,
            0.000384603140027, 1.00558320345, -25.9619351461,
            1.97324405584e-07, 1.22268102386e-06, 1],
      ],
      484: [
        -4: [0.996559953155, -0.00385087518147, 11.6332491622,
            -0.00019677300617, 0.994491548362, 25.0937476922,
            -1.58901633084e-07, -1.24978030574e-06, 1],
        -3: [0.997380631922, -0.00278591900343, 8.92203039769,
            -0.000200974918309, 0.995858422844, 19.0067063458,
            -1.30195696318e-07, -9.28664194585e-07, 1],
        -2: [0.998094133767, -0.00190403627659, 6.31253026827,
            -0.00015784739729, 0.997149020134, 12.7366790317,
            -1.07495563423e-07, -6.29657169901e-07, 1],
        -1: [0.999068171784, -0.000753584392707, 2.80041380587,
            -7.48677484461e-05, 0.998715372096, 6.16690029733,
            -6.0881608353e-08, -2.83163430941e-07, 1],
        1: [1.00106240256, 0.00102367922867, -3.41466653736,
            0.000120379858513, 1.00154131454, -6.627825966,
            6.42658098032e-08, 3.34198184538e-07, 1],
        2: [1.00179928156, 0.00179525412441, -6.23420548517,
            0.000204450357248, 1.00279344552, -13.0687629986,
            9.57917223724e-08, 6.01055625397e-07, 1],
        3: [1.00289524308, 0.00287044567315, -9.70119148654,
            0.00031620696702, 1.00430723627, -19.5790296982,
            1.62654651106e-07, 9.47605366851e-07, 1],
        4: [1.00381639065, 0.0038740467107, -12.814987121,
            0.000364667881802, 1.00573162975, -25.9697210623,
            2.04825397142e-07, 1.27724270372e-06, 1],
      ],
      485: [
        -4: [0.996440488928, -0.00369322666323, 12.0448489702,
            -0.000295852027034, 0.994468736032, 25.4584643321,
            -1.84331515798e-07, -1.22931152271e-06, 1],
        -3: [0.997256498286, -0.00275208040585, 9.23843527873,
            -0.000255556388597, 0.995785209597, 19.2502355892,
            -1.50205559173e-07, -9.15593008851e-07, 1],
        -2: [0.998138359899, -0.00183340977828, 6.19335580695,
            -0.000179668751673, 0.997169047076, 12.8774098452,
            -1.04222629671e-07, -6.11349416772e-07, 1],
        -1: [0.999015778713, -0.000938134236885, 3.19603202429,
            -0.00010392689644, 0.998547644511, 6.50321891755,
            -5.73886583073e-08, -3.17333265093e-07, 1],
        1: [1.00106337296, 0.000914499526523, -3.32028857636,
            0.000137433266453, 1.0015200817, -6.65681028898,
            7.08354571808e-08, 3.12144620908e-07, 1],
        2: [1.00182376681, 0.00178064065139, -6.15368327899,
            0.000240050725183, 1.00274642922, -13.1312047984,
            1.03278924953e-07, 5.89866740414e-07, 1],
        3: [1.00269048966, 0.00282548827368, -9.22394777289,
            0.000218704956104, 1.0042354037, -19.2551966131,
            1.34923338515e-07, 9.45356465376e-07, 1],
        4: [1.00356391589, 0.00375515372095, -11.9763993978,
            0.00026235934808, 1.00556120254, -25.5935690557,
            1.7758739079e-07, 1.23643070303e-06, 1],
      ],
      486: [
        -4: [0.996298098662, -0.00371803481407, 12.4776989587,
            -0.000343558666509, 0.994368322911, 25.5967309656,
            -2.05392695129e-07, -1.23494167372e-06, 1],
        -3: [0.997247709191, -0.00276790445719, 9.37831177698,
            -0.000271664819577, 0.995785333768, 19.3243694289,
            -1.4932782658e-07, -9.23146587387e-07, 1],
        -2: [0.998186711261, -0.0018239900142, 6.27244768424,
            -0.000211126078277, 0.997188561678, 13.0698825676,
            -9.77772001813e-08, -6.06473331034e-07, 1],
        -1: [0.999032375626, -0.00097932863912, 3.2871897716,
            -0.000101837573855, 0.998539370115, 6.48777625325,
            -5.42759453399e-08, -3.24204317822e-07, 1],
        1: [1.00099627077, 0.00101044549904, -3.30547176852,
            0.000105525949865, 1.00147356363, -6.55350352387,
            5.66393953574e-08, 3.22639334054e-07, 1],
        2: [1.00200436519, 0.0020668045646, -6.46842165355,
            0.000161146673047, 1.00295275504, -12.8492566286,
            1.12739258663e-07, 6.63629494577e-07, 1],
        3: [1.00251269181, 0.00275915240141, -8.52788804802,
            0.000128894614009, 1.00405007271, -18.9426824085,
            1.13415245608e-07, 9.06738447641e-07, 1],
        4: [1.00343391212, 0.00390208462779, -11.3723745292,
            0.000127508282337, 1.00554453799, -25.2208759519,
            1.48089401539e-07, 1.25691144535e-06, 1],
      ],
    ]
    static let repaired: [Int: [Int: [Double]]] = [
      481: [
        -4: [0.997720386722, -0.00414750136416, 7.43421180079,
            0.000515380031761, 0.995030713509, 23.1223887565,
            3.54384066514e-08, -1.24490086794e-06, 1],
        -3: [0.998272774074, -0.00308516547153, 5.47366443449,
            0.000390667649195, 0.996251031262, 17.328720074,
            2.05464611589e-08, -9.24499866384e-07, 1],
        -2: [0.998875774867, -0.00206074477117, 3.68890928939,
            0.000254843825861, 0.997544600964, 11.5623915401,
            1.90879135101e-08, -6.13928474744e-07, 1],
        -1: [0.99942251355, -0.00100110605614, 1.87500823241,
            0.000115741516941, 0.998773469305, 5.8604724632,
            8.261147888e-09, -3.02280529775e-07, 1],
        1: [1.00051785304, 0.00100199233298, -1.71276411609,
            -0.000136912737448, 1.00118282609, -5.77905776904,
            -1.57147935223e-08, 3.02552275451e-07, 1],
        2: [1.00107259182, 0.00206997885146, -3.50872249585,
            -0.000274838739924, 1.00242552372, -11.5632850044,
            -2.97552232272e-08, 6.18704465972e-07, 1],
        3: [1.00164540565, 0.00309944220979, -5.32687153536,
            -0.000414706890235, 1.00366983221, -17.3265507663,
            -3.96926736357e-08, 9.29902158696e-07, 1],
        4: [1.00211386656, 0.00406109941096, -6.84533915522,
            -0.000572038677253, 1.00481996917, -23.0253764317,
            -6.1163365788e-08, 1.22119307292e-06, 1],
      ],
      482: [
        -4: [0.997445839707, -0.00402015989722, 8.41931986685,
            0.0003236850472, 0.994906273785, 23.6826104526,
            -1.30077807559e-08, -1.23850240339e-06, 1],
        -3: [0.998029126418, -0.0030718018202, 6.24491751605,
            0.000249107815626, 0.996092398514, 17.7747811475,
            -1.77615818137e-08, -9.36867861961e-07, 1],
        -2: [0.998772780886, -0.00201076534481, 4.05215393438,
            0.000185095256263, 0.997491874333, 11.752925471,
            1.03780932802e-09, -6.13964052488e-07, 1],
        -1: [0.999380437062, -0.000969307134321, 2.00515731658,
            8.84125256213e-05, 0.998745800689, 5.92082543235,
            -8.99808101361e-10, -2.99078574883e-07, 1],
        1: [1.00052133275, 0.000967135106018, -1.74359701146,
            -0.000118768633037, 1.00118435097, -5.84184763973,
            -1.32918138476e-08, 2.95753019272e-07, 1],
        2: [1.00110092715, 0.00204832703481, -3.59247314118,
            -0.000240854591654, 1.0024348278, -11.6692902545,
            -2.51929447831e-08, 6.18469446633e-07, 1],
        3: [1.00163050136, 0.00303404995559, -5.32320796356,
            -0.000379185466524, 1.00364497564, -17.4323912281,
            -3.89680464265e-08, 9.1911445639e-07, 1],
        4: [1.00210050736, 0.00399452451753, -6.81204307431,
            -0.000526093002661, 1.0048071949, -23.181908996,
            -6.09977822951e-08, 1.21138250688e-06, 1],
      ],
    ]
    }

    /// The frame size the incident sequence was shot at.
    private let probes = HomographyReciprocity.probePoints(width: 6000, height: 4000)!

    private func results(
      forFrame frameIndex: Int,
      from table: [Int: [Int: [Double]]]
    ) -> HomographyResultsCodable {
        HomographyResultsCodable(
          for: frameIndex,
          with: (table[frameIndex] ?? [:]).map { offset, matrix in
              AlignmentWarpInfoCodable(homography: matrix,
                                       alignmentState: .homographySuccess,
                                       frameIndex: frameIndex + offset)
          }
        )
    }

    /// Every measured frame in the window, as the partner lookup the check wants.
    private func measuredPartner(_ frameIndex: Int) -> HomographyResultsCodable? {
        guard Incident.measured[frameIndex] != nil else { return nil }
        return results(forFrame: frameIndex, from: Incident.measured)
    }

    // MARK: - the check itself

    /// A homography and the inverse of the partner frame's own fit of the same pair
    /// describe the same relative motion, so on correct data they agree closely.
    func testMeasuredSetsAgreeWithTheirPartners() throws {
        for frameIndex in 481...482 {
            let score = try XCTUnwrap(
              HomographyReciprocity.score(of: results(forFrame: frameIndex,
                                                      from: Incident.measured),
                                          partnerSet: measuredPartner,
                                          at: probes),
              "frame \(frameIndex)")
            XCTAssertLessThan(score, ReciprocityLimits.frameRejection,
                              "frame \(frameIndex) measured set should read as consistent")
            // measured 0.377 and 0.128px in the run this came from
            XCTAssertLessThan(score, 0.5, "frame \(frameIndex)")
        }
    }

    /// The substituted sets are the ones that produced the artifact, and this is the check
    /// that can see it.  `alignmentLooksOk` passes both of them.
    func testRepairedSetsAreCaughtByTheCheck() throws {
        for frameIndex in 481...482 {
            let repaired = results(forFrame: frameIndex, from: Incident.repaired)

            XCTAssertTrue(repaired.alignmentLooksOk,
                          "frame \(frameIndex): the internal heuristics cannot see this, " +
                          "which is the whole reason the reciprocity check exists")

            let score = try XCTUnwrap(
              HomographyReciprocity.score(of: repaired,
                                          partnerSet: measuredPartner,
                                          at: probes),
              "frame \(frameIndex)")
            XCTAssertGreaterThan(score, ReciprocityLimits.frameRejection,
                                 "frame \(frameIndex) substitute should be rejected")
            // measured 2.166 and 2.145px in the run this came from
            XCTAssertGreaterThan(score, 2.0, "frame \(frameIndex)")
        }
    }

    /// The margin between the two is what makes a single fixed threshold viable: the
    /// substitute is several times less consistent than the measurement it replaced.
    func testTheCheckSeparatesMeasuredFromSubstituted() throws {
        for frameIndex in 481...482 {
            let measured = try XCTUnwrap(
              HomographyReciprocity.score(of: results(forFrame: frameIndex,
                                                      from: Incident.measured),
                                          partnerSet: measuredPartner, at: probes))
            let repaired = try XCTUnwrap(
              HomographyReciprocity.score(of: results(forFrame: frameIndex,
                                                      from: Incident.repaired),
                                          partnerSet: measuredPartner, at: probes))
            XCTAssertGreaterThan(repaired, measured * 4, "frame \(frameIndex)")
        }
    }

    /// A frame whose size is unknown must not be measured with a degenerate probe set:
    /// every point would collapse to the origin and the check would become
    /// translation-only, agreeing with anything at the centre and disagreeing at no
    /// corner.  `Config.imageWidth`/`imageHeight` default to 0.
    func testProbePointsRefuseADegenerateFrameSize() {
        XCTAssertNil(HomographyReciprocity.probePoints(width: 0, height: 0))
        XCTAssertNil(HomographyReciprocity.probePoints(width: 6000, height: 0))
        XCTAssertNil(HomographyReciprocity.probePoints(width: 64, height: 64))
        XCTAssertEqual(HomographyReciprocity.probePoints(width: 6000, height: 4000)?.count, 5)
    }

    /// A frame next to a genuinely bad one shares a pair with it, so its own score has to
    /// survive one bad partner — which is why the score is a median and not a maximum.
    func testOneBadPartnerCannotCondemnAGoodFrame() throws {
        // frame 483's measured set, judged against partners where 481 and 482 carry the
        // substituted matrices that caused the artifact
        func mixedPartner(_ frameIndex: Int) -> HomographyResultsCodable? {
            if frameIndex == 481 || frameIndex == 482 {
                return results(forFrame: frameIndex, from: Incident.repaired)
            }
            return measuredPartner(frameIndex)
        }
        let score = try XCTUnwrap(
          HomographyReciprocity.score(of: results(forFrame: 483, from: Incident.measured),
                                      partnerSet: mixedPartner, at: probes))
        XCTAssertLessThan(score, ReciprocityLimits.frameRejection,
                          "frame 483 is correct and must not be condemned by its " +
                          "damaged neighbours")
    }

    /// Offsets whose partner says nothing are absent rather than scored as agreeing, and
    /// too few answers means no score at all instead of a median of one or two.
    func testTooFewPartnersMeansNoScore() {
        XCTAssertNil(
          HomographyReciprocity.score(of: results(forFrame: 481, from: Incident.measured),
                                      partnerSet: { _ in nil },
                                      at: probes))
        XCTAssertNil(HomographyReciprocity.median(of: [1: 0.1, 2: 0.2, 3: 0.3]))
        XCTAssertEqual(HomographyReciprocity.median(of: [1: 0.1, 2: 0.2, 3: 0.3, 4: 0.4]),
                       0.3)
    }

    // MARK: - not condemning a frame for one doubtful neighbour

    /// The measured sets that were thrown away were not uniformly doubtful: the internal
    /// heuristics flagged 3 of frame 481's 8 warps and just 1 of frame 482's, and
    /// `alignmentLooksOk` collapses that to "discard all 8" either way.
    func testTheHeuristicsFlagOnlyAFewWarpsOfACorrectSet() {
        let flagged = (481...482).map { frameIndex in
            results(forFrame: frameIndex, from: Incident.measured).partitionWarps()
        }
        XCTAssertEqual(flagged[0].suspect.count, 3, "frame 481")
        XCTAssertEqual(flagged[0].good.count, 5, "frame 481")
        XCTAssertEqual(flagged[1].suspect.count, 1, "frame 482")
        XCTAssertEqual(flagged[1].good.count, 7, "frame 482")

        // and so both frames read as entirely unusable
        for frameIndex in 481...482 {
            XCTAssertFalse(results(forFrame: frameIndex, from: Incident.measured)
                             .alignmentLooksOk,
                           "frame \(frameIndex)")
        }
    }

    /// Every warp the heuristics flagged on those two frames is independently corroborated
    /// by the partner frame's own fit of the same pair, so nothing should be pruned.  The
    /// two fits share no keypoints, no RANSAC draw and no base frame.
    func testFlaggedWarpsOfACorrectSetAreCorroborated() {
        for frameIndex in 481...482 {
            let measured = results(forFrame: frameIndex, from: Incident.measured)
            let perNeighbor = HomographyReciprocity.perNeighborDisagreement(
              of: measured, partnerSet: measuredPartner, at: probes)
            for suspect in measured.partitionWarps().suspect {
                let d = perNeighbor[suspect.frameIndex]
                XCTAssertNotNil(d, "frame \(frameIndex) offset \(suspect.frameIndex - frameIndex)")
                XCTAssertLessThanOrEqual(
                  d ?? .infinity, ReciprocityLimits.warpCorroboration,
                  "frame \(frameIndex) offset \(suspect.frameIndex - frameIndex) is a real " +
                  "measurement and its partner agrees with it")
            }
        }
    }

    /// The substituted sets do not get the same protection: their warps disagree with the
    /// partners' fits well past the corroboration limit.
    func testSubstitutedWarpsAreNotCorroborated() {
        for frameIndex in 481...482 {
            let repaired = results(forFrame: frameIndex, from: Incident.repaired)
            let perNeighbor = HomographyReciprocity.perNeighborDisagreement(
              of: repaired, partnerSet: measuredPartner, at: probes)
            let corroborated = perNeighbor.values.filter {
                $0 <= ReciprocityLimits.warpCorroboration
            }
            XCTAssertTrue(corroborated.isEmpty,
                          "frame \(frameIndex): none of the substituted warps should " +
                          "look corroborated, got \(corroborated.count) of " +
                          "\(perNeighbor.count)")
        }
    }

    /// Pruning keeps each surviving entry's own matrix and deviation, and drops only what
    /// it was asked to.  A dropped neighbour costs the merge one source; replacing the set
    /// costs it this frame's motion.
    func testPruningKeepsTheSurvivorsUntouched() throws {
        let measured = results(forFrame: 481, from: Incident.measured)
        let keep = Set(measured.partitionWarps().good.map(\.frameIndex))
        let pruned = measured.keeping(neighborFrameIndices: keep)

        XCTAssertEqual(pruned.frameIndex, 481)
        XCTAssertEqual(Set(pruned.neighborHomography.map(\.frameIndex)), keep)
        for entry in pruned.neighborHomography {
            let original = try XCTUnwrap(
              measured.neighborHomography.first { $0.frameIndex == entry.frameIndex })
            XCTAssertEqual(entry.homography, original.homography)
            XCTAssertEqual(entry.deviation, original.deviation)
        }
    }

    /// Pruning to exactly the warps that passed does **not** make a set pass
    /// `alignmentLooksOk`, and nothing may be built on the assumption that it does.
    ///
    /// The slope check is relative to the median slope *of the set being checked*, so
    /// removing the low outliers raises the median and the surviving warp nearest the
    /// floor drops through it.  On frame 481 the kept warps' ratios to the old median were
    /// 0.926, 1.000, 1.030, 1.033 and 1.070; their own median is 1.030, which puts the
    /// first of them at 0.899 against a 0.926 floor.  Chasing that to a fixed point would
    /// just strip the set one warp at a time, so classification marks a pruned frame good
    /// on the strength of how many measured warps survived and what the cross-frame check
    /// says about them, and never re-asks this property.
    func testPruningDoesNotRestoreAlignmentLooksOk() {
        let measured = results(forFrame: 481, from: Incident.measured)
        let keep = Set(measured.partitionWarps().good.map(\.frameIndex))
        XCTAssertEqual(keep.count, 5)
        XCTAssertFalse(measured.keeping(neighborFrameIndices: keep).alignmentLooksOk)
    }

    // MARK: - the gate

    func testGateKeepsAVouchedForMeasuredSet() {
        // the incident: measured 0.38px, substitute 2.17px
        XCTAssertFalse(substituteDisplacesMeasured(measuredScore: 0.38,
                                                   substituteScore: 2.17))
    }

    func testGateAcceptsASubstituteWhenTheMeasuredSetIsInconsistent() {
        XCTAssertTrue(substituteDisplacesMeasured(measuredScore: 3.0,
                                                  substituteScore: 2.17))
        // nothing vouches for the measured set at all
        XCTAssertTrue(substituteDisplacesMeasured(measuredScore: nil,
                                                  substituteScore: 2.17))
        XCTAssertTrue(substituteDisplacesMeasured(measuredScore: nil,
                                                  substituteScore: nil))
    }

    /// An unscoreable substitute never displaces a measured set that the check vouches
    /// for: "cannot be shown to be worse" is not "shown to be better".
    func testGateRefusesAnUnmeasurableSubstitute() {
        XCTAssertFalse(substituteDisplacesMeasured(measuredScore: 0.5,
                                                   substituteScore: nil))
    }

    /// A substitute has to win by a margin, so that noise between two near-equal scores
    /// does not decide whether a frame keeps its own measurement.
    func testGateRequiresAMarginNotJustABetterNumber() {
        XCTAssertFalse(substituteDisplacesMeasured(measuredScore: 1.0,
                                                   substituteScore: 0.99))
        XCTAssertTrue(substituteDisplacesMeasured(measuredScore: 1.0,
                                                  substituteScore: 0.5))
    }

    // MARK: - donor selection

    /// A homography set whose translation is linear in the offset at a given rate, so a
    /// donor picked from the wrong place in a sequence is identifiable by its rate.
    private func set(forFrame frameIndex: Int, rate: Double) -> HomographyResultsCodable {
        HomographyResultsCodable(
          for: frameIndex,
          with: [-4, -3, -2, -1, 1, 2, 3, 4].map { offset in
              let d = Double(offset)
              return AlignmentWarpInfoCodable(
                homography: [1, 0, rate * d,
                             0, 1, -6 * d,
                             0, 0, 1],
                alignmentState: .homographySuccess,
                frameIndex: frameIndex + offset)
          })
    }

    /// The defect this replaced: ranking 20 candidates by composite deviation and taking
    /// the median put the donor in the middle of the window, about ten frames out.  Here
    /// frames 461-480 are all good and the segment starts at 481, so the donor must be
    /// 480 — the frame whose motion is closest to the one being replaced.
    func testDonorIsTheAdjacentGoodFrameNotOneTenBack() throws {
        var homographies = [HomographyResultsCodable?](repeating: nil, count: 500)
        var goodFlags = [Bool](repeating: false, count: 500)
        for frameIndex in 461...480 {
            // a pan rate that ramps, as the incident sequence's did
            homographies[frameIndex] = set(forFrame: frameIndex,
                                           rate: -1.7 - 0.035 * Double(frameIndex - 461))
            goodFlags[frameIndex] = true
        }
        let donor = try XCTUnwrap(nearestGoodHomography(before: 481,
                                                        in: homographies,
                                                        goodFlags: goodFlags))
        XCTAssertEqual(donor.frameIndex, 480)
    }

    func testDonorAfterIsTheAdjacentGoodFrame() throws {
        var homographies = [HomographyResultsCodable?](repeating: nil, count: 500)
        var goodFlags = [Bool](repeating: false, count: 500)
        for frameIndex in 483...495 {
            homographies[frameIndex] = set(forFrame: frameIndex, rate: -3.0)
            goodFlags[frameIndex] = true
        }
        let donor = try XCTUnwrap(nearestGoodHomography(after: 482,
                                                        in: homographies,
                                                        goodFlags: goodFlags))
        XCTAssertEqual(donor.frameIndex, 483)
    }

    /// A frame that is not flagged good is not a donor even though it has a homography —
    /// that is what stops a substitute from seeding the next substitute.
    func testUnflaggedFramesAreNotDonors() throws {
        var homographies = [HomographyResultsCodable?](repeating: nil, count: 20)
        var goodFlags = [Bool](repeating: false, count: 20)
        for frameIndex in 0..<20 {
            homographies[frameIndex] = set(forFrame: frameIndex, rate: -2)
        }
        goodFlags[3] = true          // the only measured set in the run
        let donor = try XCTUnwrap(nearestGoodHomography(before: 10,
                                                        in: homographies,
                                                        goodFlags: goodFlags))
        XCTAssertEqual(donor.frameIndex, 3)
    }

    func testDonorSearchHonoursItsWindowAndTheSequenceEnds() {
        var homographies = [HomographyResultsCodable?](repeating: nil, count: 40)
        var goodFlags = [Bool](repeating: false, count: 40)
        homographies[0] = set(forFrame: 0, rate: -2)
        goodFlags[0] = true

        // too far back to be worth borrowing from
        XCTAssertNil(nearestGoodHomography(before: 30, in: homographies,
                                           goodFlags: goodFlags, checking: 20))
        XCTAssertNotNil(nearestGoodHomography(before: 20, in: homographies,
                                              goodFlags: goodFlags, checking: 20))
        // nothing before the first frame, nothing after the last
        XCTAssertNil(nearestGoodHomography(before: 0, in: homographies,
                                           goodFlags: goodFlags))
        XCTAssertNil(nearestGoodHomography(after: 39, in: homographies,
                                           goodFlags: goodFlags))
        XCTAssertNil(nearestGoodHomography(after: 40, in: homographies,
                                           goodFlags: goodFlags))
    }

    // MARK: - interpolation weighting

    /// With donors at unequal distances, weighting by frame distance and weighting by
    /// position in the bad segment disagree, and only the first puts the result where the
    /// frame actually is.  A segment of one frame at index 490 between donors at 489 and
    /// 495 should sit a sixth of the way across, not halfway.
    func testDistanceWeightingPlacesTheFrameWhereItIs() throws {
        let left = set(forFrame: 489, rate: 0)      // tx = 0 at every offset
        let right = set(forFrame: 495, rate: -6)    // tx = -6 * offset

        let span = Double(right.frameIndex - left.frameIndex)
        let distanceAlpha = Double(490 - left.frameIndex) / span
        let positionalAlpha = Double(1) / Double(2)   // idx-start+1 over end-start+2
        XCTAssertEqual(distanceAlpha, 1.0 / 6.0, accuracy: 1e-12)
        XCTAssertNotEqual(distanceAlpha, positionalAlpha, accuracy: 0.01)

        let blended = interpolateHomography(
          left, right,
          toFrameIndex: 490,
          targetNeighborFrameIndices: (486...494).filter { $0 != 490 },
          alpha: distanceAlpha)
        let atPlusOne = try XCTUnwrap(
          blended.first { $0.frameIndex == 491 }?.homography)
        // a sixth of the way from 0 towards -6
        XCTAssertEqual(atPlusOne[2], -1.0, accuracy: 1e-12)
    }

    // MARK: - the classification decision, on the data from the incident

    /// The regression this whole change exists for.  Frames 481 and 482's measured sets
    /// must survive classification intact: the internal heuristics distrust 3 and 1 of
    /// their warps respectively, every one of those is corroborated by the partner frame's
    /// own fit, and the cross-frame check finds the sets consistent.  Before this, both
    /// frames were classified bad and had all eight of their homographies replaced.
    func testTheIncidentFramesKeepTheirMeasuredHomographies() {
        for frameIndex in 481...482 {
            let verdict = classifyStarHomography(
              results(forFrame: frameIndex, from: Incident.measured),
              probes: probes,
              partnerSet: measuredPartner)
            switch verdict {
            case .keepAsMeasured(let corroborated):
                XCTAssertEqual(corroborated, frameIndex == 481 ? 3 : 1,
                               "frame \(frameIndex)")
            default:
                XCTFail("frame \(frameIndex) should keep its measured homography, " +
                        "got \(verdict)")
            }
        }
    }

    /// Their correct neighbours are unaffected: nothing is distrusted, nothing corroborated,
    /// nothing pruned.
    func testTheNeighbouringFramesAreUntouched() {
        for frameIndex in [477, 478, 479, 480, 483, 484, 485, 486] {
            let verdict = classifyStarHomography(
              results(forFrame: frameIndex, from: Incident.measured),
              probes: probes,
              partnerSet: measuredPartner)
            guard case .keepAsMeasured(let corroborated) = verdict else {
                XCTFail("frame \(frameIndex) should keep its measured homography, " +
                        "got \(verdict)")
                continue
            }
            XCTAssertEqual(corroborated, 0, "frame \(frameIndex)")
        }
    }

    /// The substituted sets are what classification must reject, and it rejects them on
    /// the cross-frame check — `alignmentLooksOk` passes them, so nothing else would.
    func testTheSubstitutedSetsAreRejected() {
        for frameIndex in 481...482 {
            let verdict = classifyStarHomography(
              results(forFrame: frameIndex, from: Incident.repaired),
              probes: probes,
              partnerSet: measuredPartner)
            guard case .needsRepair(let score) = verdict else {
                XCTFail("frame \(frameIndex) substitute should be rejected, got \(verdict)")
                continue
            }
            XCTAssertNotNil(score, "frame \(frameIndex) should be rejected by the " +
                                   "reciprocity check specifically")
            XCTAssertGreaterThan(score ?? 0, ReciprocityLimits.frameRejection)
        }
    }

    /// Without the cross-frame check there is nothing to reject a smooth-but-wrong set
    /// with, which is the state of the world this change moved away from.
    func testWithoutProbesTheSubstitutedSetsLookFine() {
        for frameIndex in 481...482 {
            let verdict = classifyStarHomography(
              results(forFrame: frameIndex, from: Incident.repaired),
              probes: nil,
              partnerSet: measuredPartner)
            guard case .keepAsMeasured = verdict else {
                XCTFail("frame \(frameIndex): expected the old behaviour, got \(verdict)")
                continue
            }
        }
    }

    /// And with the check disabled, the measured sets are the ones thrown away — the
    /// original defect, reproduced.
    func testWithoutProbesTheMeasuredSetsAreCondemned() {
        for frameIndex in 481...482 {
            let verdict = classifyStarHomography(
              results(forFrame: frameIndex, from: Incident.measured),
              probes: nil,
              partnerSet: measuredPartner)
            switch verdict {
            case .keepPruned(let pruned, _, let dropped):
                // frame 481 keeps 5 of 8, frame 482 keeps 7 of 8: still better than the
                // old behaviour of replacing the set, but it does lose real measurements
                XCTAssertEqual(dropped, frameIndex == 481 ? 3 : 1, "frame \(frameIndex)")
                XCTAssertGreaterThanOrEqual(pruned.neighborHomography.count,
                                            ReciprocityLimits.minimumKeptWarps)
            default:
                XCTFail("frame \(frameIndex): expected pruning, got \(verdict)")
            }
        }
    }

    /// A set with nothing usable in it, or none at all, needs a full repair and says so
    /// without claiming a reciprocity score it never measured.
    func testAnUnusableSetNeedsRepairWithoutAScore() {
        guard case .needsRepair(let score) = classifyStarHomography(
                nil, probes: probes, partnerSet: measuredPartner)
        else { return XCTFail("a missing set needs repair") }
        XCTAssertNil(score)

        // a set whose entries all failed to align
        let failed = HomographyResultsCodable(
          for: 481,
          with: [-2, -1, 1, 2].map {
              AlignmentWarpInfoCodable(homography: nil,
                                       alignmentState: .noHomographyFound,
                                       frameIndex: 481 + $0)
          })
        guard case .needsRepair = classifyStarHomography(
                failed, probes: probes, partnerSet: measuredPartner)
        else { return XCTFail("a set with no successful alignment needs repair") }
    }

    /// Pruning stops being the answer once too little of the measured set is left to
    /// stand on: below `minimumKeptWarps` the frame goes for a full repair instead.
    func testTooFewSurvivingWarpsFallsThroughToRepair() {
        let measured = results(forFrame: 481, from: Incident.measured)
        // keep only three of the eight, none of which any partner can corroborate
        let thin = measured.keeping(
          neighborFrameIndices: Set(measured.neighborHomography.prefix(3).map(\.frameIndex)))
        XCTAssertEqual(thin.neighborHomography.count, 3)
        guard case .needsRepair = classifyStarHomography(
                thin, probes: probes, partnerSet: { _ in nil })
        else { return XCTFail("three warps is not enough to keep") }
    }
}
