using Test
using LAMMPS
using MPI; MPI.Init()
using UnsafeArrays

@test_logs (:warn,"LAMMPS library path changed, you will need to restart Julia for the change to take effect") LAMMPS.set_library!(LAMMPS.locate())

LMP() do lmp
    @test LAMMPS.version(lmp) >= 0
end

LMP(["-screen", "none"]) do lmp
    @test LAMMPS.version(lmp) >= 0
    command(lmp, "clear")

    @test_throws LAMMPSError command(lmp, "nonsense")

    LAMMPS.close!(lmp)

    expected_error = ErrorException("The LMP object doesn't point to a valid LAMMPS instance! "
        * "This is usually caused by calling `LAMMPS.close!` or through serialization and deserialization.")

    @test_throws expected_error command(lmp, "")
end

@test_throws LAMMPSError LMP(["-nonesense"])

@testset "Extract Setting/Global" begin
    LMP(["-screen", "none"]) do lmp
        command(lmp, """
                atom_modify map yes
                region cell block 0 1 0 2 0 3
                create_box 1 cell
        """)

        @test extract_global(lmp, "dt", LAMMPS_DOUBLE)[] isa Float64
        @test extract_global(lmp, "boxhi", LAMMPS_DOUBLE) == [1, 2, 3]
        @test extract_global(lmp, "nlocal", LAMMPS_INT)[] == extract_setting(lmp, "nlocal") == 0

        # verify that no errors were missed
        @test LAMMPS.API.lammps_has_error(lmp) == 0
    end
end

@testset "Extract Atom" begin
    LMP(["-screen", "none"]) do lmp
        command(lmp, """
            atom_modify map yes
            region cell block 0 3 0 3 0 3
            create_box 1 cell
            lattice sc 1
            create_atoms 1 region cell
            mass 1 1
        """)

        @test extract_atom(lmp, "mass", LAMMPS_DOUBLE) isa UnsafeArray{Float64, 1}
        @test extract_atom(lmp, "mass", LAMMPS_DOUBLE) == [1]

        x1 = extract_atom(lmp, "x", LAMMPS_DOUBLE_2D) 
        @test size(x1) == (3, 27)

        x2 = extract_atom(lmp, "x", LAMMPS_DOUBLE_2D; with_ghosts=true) 
        @test size(x2) == (3, 27)

        @test extract_atom(lmp, "image", LAMMPS_INT) isa UnsafeArray{Int32, 1}

        @test_throws ErrorException extract_atom(lmp, "v", LAMMPS_DOUBLE)

        # verify that no errors were missed
        @test LAMMPS.API.lammps_has_error(lmp) == 0
    end
end


function f()
    lmp = LMP(["-screen", "none"])
    @test LAMMPS.version(lmp) >= 0
    command(lmp, "clear")
    @test_throws ErrorException command(lmp, "nonsense")
    LAMMPS.close!(lmp)
end


@testset "Variables" begin
    LMP(["-screen", "none"]) do lmp
        command(lmp, """
            box tilt large
            region cell block 0 1.0 0 1.0 0 1.0 units box
            create_box 1 cell
            create_atoms 1 random 10 1 NULL
            compute  press all pressure NULL pair
            fix press all ave/time 1 1 1 c_press mode vector

            variable var1 equal 1.0
            variable var2 string \"hello\"
            variable var3 atom x
            # TODO: x is 3d, how do we access more than the first dims
            variable var4 vector f_press
            group odd id 1 3 5 7
        """)

        @test extract_variable(lmp, "var1", VAR_EQUAL) == 1.0
        @test extract_variable(lmp, "var2", VAR_STRING) == "hello"
        x = extract_atom(lmp, "x", LAMMPS_DOUBLE_2D)
        x_var = extract_variable(lmp, "var3", VAR_ATOM)
        @test length(x_var) == 10
        @test x_var == x[1, :]
        press = extract_variable(lmp, "var4", VAR_VECTOR)
        @test press isa UnsafeArray{Float64, 1}

        x_var_group = extract_variable(lmp, "var3", VAR_ATOM, "odd")
        in_group = BitVector((1, 0, 1, 0, 1, 0, 1, 0, 0, 0))

        @test x_var_group[in_group] == x[1, in_group]
        @test all(x_var_group[.!in_group] .== 0)

        @test_throws ErrorException extract_variable(lmp, "var3", VAR_EQUAL)

        # verify that no errors were missed
        @test LAMMPS.API.lammps_has_error(lmp) == 0
    end

    # check if the memory allocated by LAMMPS persists after closing the instance
    lmp = LMP(["-screen", "none"])
    command(lmp, """
        atom_modify map yes
        region cell block 0 3 0 3 0 3
        create_box 1 cell
        lattice sc 1
        create_atoms 1 region cell
        mass 1 1

        variable var atom id
    """)

    var = extract_variable(lmp, "var", VAR_ATOM)
    var_copy = copy(var)
    LAMMPS.close!(lmp)

    @test var == var_copy

end

@testset "gather/scatter" begin
    LMP(["-screen", "none"]) do lmp
        # setting up example data
        command(lmp, """
            atom_modify map yes
            region cell block 0 3 0 3 0 3
            create_box 1 cell
            lattice sc 1
            create_atoms 1 region cell
            mass 1 1

            compute pos all property/atom x y z
            fix pos all ave/atom 10 1 10 c_pos[1] c_pos[2] c_pos[3]

            run 10
        """)

        data = zeros(Float64, 3, 27)
        subset = Int32.([2,5,10, 5])
        data_subset = ones(Float64, 3, 4)

        subset_bad1 = Int32.([28])
        subset_bad2 = Int32.([0])
        subset_bad_data = ones(Float64, 3,1)

        @test_throws AssertionError gather(lmp, "x", Int32)
        @test_throws AssertionError gather(lmp, "id", Float64)

        @test_throws ErrorException gather(lmp, "nonesense", Float64)
        @test_throws ErrorException gather(lmp, "c_nonsense", Float64)
        @test_throws ErrorException gather(lmp, "f_nonesense", Float64)

        @test_throws AssertionError gather(lmp, "x", Float64, subset_bad1)
        @test_throws AssertionError gather(lmp, "x", Float64, subset_bad2)

        @test_throws ErrorException scatter!(lmp, "nonesense", data)
        @test_throws ErrorException scatter!(lmp, "c_nonsense", data)
        @test_throws ErrorException scatter!(lmp, "f_nonesense", data)

        @test_throws AssertionError scatter!(lmp, "x", subset_bad_data, subset_bad1)
        @test_throws AssertionError scatter!(lmp, "x", subset_bad_data, subset_bad2)

        @test gather(lmp, "x", Float64) == gather(lmp, "c_pos", Float64) == gather(lmp, "f_pos", Float64)

        @test gather(lmp, "x", Float64)[:,subset] == gather(lmp, "x", Float64, subset)
        @test gather(lmp, "c_pos", Float64)[:,subset] == gather(lmp, "c_pos", Float64, subset)
        @test gather(lmp, "f_pos", Float64)[:,subset] == gather(lmp, "f_pos", Float64, subset)

        scatter!(lmp, "x", data)
        scatter!(lmp, "f_pos", data)
        scatter!(lmp, "c_pos", data)

        @test gather(lmp, "x", Float64) == gather(lmp, "c_pos", Float64) == gather(lmp, "f_pos", Float64) == data

        scatter!(lmp, "x", data_subset, subset)
        scatter!(lmp, "c_pos", data_subset, subset)
        scatter!(lmp, "f_pos", data_subset, subset)

        @test gather(lmp, "x", Float64, subset) == gather(lmp, "c_pos", Float64, subset) == gather(lmp, "f_pos", Float64, subset) == data_subset

        # verify that no errors were missed
        @test LAMMPS.API.lammps_has_error(lmp) == 0
    end
end

@testset "Gather bonds/angles/dihedrals/impropers" begin
    LMP(["-screen", "none"]) do lmp
        file = joinpath(@__DIR__, "test_files/bonds_angles_dihedrals_impropers.data")

        command(lmp,  """
            atom_style molecular
            read_data $file
            """)

        @test gather_bonds(lmp) == transpose([
            1 1 2
            1 2 3
            1 3 4
            1 4 1
        ])
        @test gather_angles(lmp) == transpose([
            1 1 2 3
            1 2 3 4
        ])
        @test gather_angles(lmp) == transpose([
            1 1 2 3
            1 2 3 4
        ])
        @test gather_dihedrals(lmp) == transpose([
            1 1 2 3 4
        ])
        @test gather_impropers(lmp) == transpose([
            1 4 3 2 1
        ])
        @test LAMMPS.API.lammps_has_error(lmp) == 0
    end
end

@testset "Extract Compute" begin
    LMP(["-screen", "none"]) do lmp
        command(lmp, """
            atom_modify map yes
            region cell block 0 3 0 3 0 3
            create_box 1 cell
            lattice sc 1
            create_atoms 1 region cell
            mass 1 1

            compute pos all property/atom x y z
        """)

        @test extract_compute(lmp, "pos", STYLE_ATOM, TYPE_ARRAY) == extract_atom(lmp, "x", LAMMPS_DOUBLE_2D)

        extract_compute(lmp, "thermo_temp", STYLE_GLOBAL, TYPE_VECTOR)[3] = 3

        @test extract_compute(lmp, "thermo_temp", STYLE_GLOBAL, TYPE_SCALAR) == [0.0]
        @test extract_compute(lmp, "thermo_temp", STYLE_GLOBAL, TYPE_VECTOR) == [0.0, 0.0, 3.0, 0.0, 0.0, 0.0]

        @test_throws LAMMPSError extract_compute(lmp, "thermo_temp", STYLE_ATOM, TYPE_SCALAR)
        @test_throws LAMMPSError extract_compute(lmp, "thermo_temp", STYLE_GLOBAL, TYPE_ARRAY)

        # verify that no errors were missed
        @test LAMMPS.API.lammps_has_error(lmp) == 0
    end
end

@testset "Utilities" begin
    LMP(["-screen", "none"]) do lmp
        # setting up example data
        command(lmp, """
            atom_modify map yes
            region cell block 0 2 0 2 0 2
            create_box 1 cell
            lattice sc 1
            create_atoms 1 region cell
            mass 1 1

            group a id 1 2 3 5 8
            group even id 2 4 6 8
            group odd id 1 3 5 7
        """)

        @test group_to_atom_ids(lmp, "all") == 1:8
        @test group_to_atom_ids(lmp, "a") == [1, 2, 3, 5, 8]
        @test group_to_atom_ids(lmp, "even") == [2, 4, 6, 8]
        @test group_to_atom_ids(lmp, "odd") == [1, 3, 5, 7]
        @test_throws ErrorException group_to_atom_ids(lmp, "nonesense")

        command(lmp, [
            "compute pos all property/atom x y z",
            "fix 1 all ave/atom 10 1 10 c_pos[*]",
            "run 10"
        ])

        @test get_category_ids(lmp, "group") == ["all", "a", "even", "odd"]
        @test get_category_ids(lmp, "compute") == ["thermo_temp", "thermo_press", "thermo_pe", "pos"] # some of these computes are there by default it seems
        @test get_category_ids(lmp, "fix") == ["1"]
        @test_throws ErrorException get_category_ids(lmp, "nonesense")

        # verify that no errors were missed
        @test LAMMPS.API.lammps_has_error(lmp) == 0
    end
end

@testset "Create Atoms" begin
    LMP(["-screen", "none"]) do lmp
        command(lmp, """
            atom_modify map yes
            region cell block 0 2 0 2 0 2
            create_box 1 cell
            lattice sc 1
        """)
        x = rand(3, 100)
        id = Int32.(collect(1:100))
        types = ones(Int32, 100)
        image = ones(Int32, 100)
        v = rand(3, 100)


        create_atoms(lmp, x, id, types, v=v, image=image, bexpand=true)
        # Normally, you would have to sort by id, but we haven't done anything, so lammps
        # will still have the same order
        @test all(x .== extract_atom(
            lmp, "x", LAMMPS_DOUBLE_2D
        ))
        @test all(v .== extract_atom(
            lmp, "v", LAMMPS_DOUBLE_2D
        ))

        command(lmp, """
            clear
            atom_modify map yes
            region cell block 0 2 0 2 0 2
            create_box 1 cell
            lattice sc 1
        """)
        create_atoms(lmp, x, id, types, bexpand=true)
        @test all(zeros(3,100) .== extract_atom(
            lmp, "v", LAMMPS_DOUBLE_2D
        ))

        @test_throws ArgumentError create_atoms(lmp, x[1:2,:], id, types; v, image, bexpand=true) 
        @test_throws ArgumentError create_atoms(lmp, x, id[1:99], types; v, image, bexpand=true) 
        @test_throws ArgumentError create_atoms(lmp, x, id, types[1:99]; v, image, bexpand=true) 
        @test_throws ArgumentError create_atoms(lmp, x, id, types; v=v[1:2,:], image, bexpand=true)
        @test_throws ArgumentError create_atoms(lmp, x, id, types; v, image=image[1:99], bexpand=true) 

    end
end

@testset "Custom Properties" begin
    LMP(["-screen", "none"]) do lmp
        command(lmp, """
            atom_modify map yes
            region cell block 0 3 0 3 0 3
            create_box 1 cell
            lattice sc 1
            create_atoms 1 region cell
            mass 1 1

            fix customprop all property/atom i_int i2_int2 5 d_float d2_float2 6
        """)

        i_int = extract_atom(lmp, "i_int", LAMMPS_INT)
        @test size(i_int) == (27,)
        @test all(iszero, i_int)

        i2_int2 = extract_atom(lmp, "i2_int2", LAMMPS_INT_2D)
        @test size(i2_int2) == (5, 27)
        @test all(iszero, i2_int2)

        d_float = extract_atom(lmp, "d_float", LAMMPS_DOUBLE)
        @test size(d_float) == (27,)
        @test all(iszero, d_float)

        d2_float2 = extract_atom(lmp, "d2_float2", LAMMPS_DOUBLE_2D)
        @test size(d2_float2) == (6, 27)
        @test all(iszero, d2_float2)

        # verify that no errors were missed
        @test LAMMPS.API.lammps_has_error(lmp) == 0
    end
end

@testset "Image Flags" begin
    @test encode_image_flags(0, 0, 0) == 537395712
    @test encode_image_flags((0, 0, 0)) == 537395712
    @test decode_image_flags(537395712) == (0, 0, 0)
end

@testset "Extract Box" begin
    LMP(["-screen", "none"]) do lmp
        command(lmp, """
            region cell block -1 1 -2 2 -3 3
            boundary p p f
            create_box 1 cell
        """)

        box = extract_box(lmp)
        @test box.boxlo == (-1, -2, -3)
        @test box.boxhi == (1, 2, 3)
        @test box.xy == box.yz == box.xz == 0
        @test box.pflags == (1, 1, 0)
        @test box.boxflag == 0

        reset_box(lmp, [0, 0, 0], [1, 1, 1], 1, 2, 3)
        box = extract_box(lmp)
        @test box.boxlo == (0, 0, 0)
        @test box.boxhi == (1, 1, 1)
        @test box.xy == 1
        @test box.yz == 2
        @test box.xz == 3

        # verify that no errors were missed
        @test LAMMPS.API.lammps_has_error(lmp) == 0
    end
end

@testset "Neighbor lists" begin
    LMP(["-screen", "none"]) do lmp
        command(lmp, """
            atom_modify map yes
            region cell block 0 3 0 3 0 3
            create_box 1 cell
            lattice sc 1
            create_atoms 1 region cell
            mass 1 1

            pair_style zero 1.0
            pair_coeff * *

            fix runfix all nve

            run 1
        """)

        neighlist = pair_neighborlist(lmp, "zero")
        @test length(neighlist) == 27
        iatom, neihgs = neighlist[1]
        @test iatom == 1 # account for 1-based indexing
        @test length(neihgs) == 3
        @test_throws KeyError pair_neighborlist(lmp, "nonesense")
    end
end

LMP(["-screen", "none"]) do lmp
    called = Ref(false)
    command(lmp, "boundary p p p")
    command(lmp, "region cell block 0 1 0 1 0 1 units box")
    command(lmp, "create_box 1 cell")
    LAMMPS.FixExternal(lmp, "julia", "all", 1, 1) do fix
        called[] = true
    end
    command(lmp, "mass 1 1.0")
    command(lmp, "run 0")
    @test called[] == true
end

include("external_pair.jl")

if !Sys.iswindows()
    @testset "MPI" begin
         @test success(pipeline(`$(MPI.mpiexec()) -n 2 $(Base.julia_cmd()) mpitest.jl`, stderr=stderr, stdout=stdout))
    end
end