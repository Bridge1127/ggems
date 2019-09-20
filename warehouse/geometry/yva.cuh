// This file is part of GGEMS
//
// GGEMS is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// GGEMS is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with GGEMS.  If not, see <http://www.gnu.org/licenses/>.
//
// GGEMS Copyright (C) 2013-2014 Julien Bert

#ifndef YVA_CUH
#define YVA_CUH

#include "voxelized.cuh"
#include "meshed.cuh"
#include "global.cuh"

// hYbrid Voxelized/Analytical object (YVA)
class YVA : public Voxelized {
    public:
        YVA();
        void include(Meshed obj, ui32 obj_id);
        void build_regular_octree(ui32 nx, ui32 ny, ui32 nz);
        void build_voxel_octree();

        // TODO
        // build_voxel_octree
        // build_regular_octree

    private:

        //bool *overlap_vox;
        Meshed mesh;
        ui32 mesh_id;


};




#endif
