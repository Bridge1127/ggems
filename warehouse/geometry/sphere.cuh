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

#ifndef SPHERE_H
#define SPHERE_H

#include "global.cuh"
#include "base_object.cuh"

// Sphere
class Sphere : public BaseObject {
    public:
        Sphere();
        Sphere(f32 ox, f32 oy, f32 oz, f32 rad,
               std::string mat_name, std::string obj_name);

        f32 cx, cy, cz, radius;

    private:
};

#endif
