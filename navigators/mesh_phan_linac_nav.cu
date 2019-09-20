// GGEMS Copyright (C) 2017

/*!
 * \file mesh_phan_linac_nav.cuh
 * \brief
 * \author J. Bert <bert.jul@gmail.com>
 * \version 0.2
 * \date Monday June 13, 2016
 *
 * v0.1: JB - First code
 * v0.2: JB - Change all structs and remove CPU exec
 * v0.3: JB - Rewrote the mesh navigation to consider overlap meshes, and add option Nav-NoMesh
 */

#ifndef MESH_PHAN_LINAC_NAV_CU
#define MESH_PHAN_LINAC_NAV_CU

#include "mesh_phan_linac_nav.cuh"

////// HOST-DEVICE GPU Codes //////////////////////////////////////////////////////////////

// == Track to in ===================================================================================

// Device Kernel that move particles to the voxelized volume boundary
__global__ void MPLINACN::kernel_device_track_to_in( ParticlesData *particles,
                                                     const LinacData *linac, f32 geom_tolerance )
{
    const ui32 id = blockIdx.x * blockDim.x + threadIdx.x;
    if ( id >= particles->size ) return;

    // read position and direction
    f32xyz pos = make_f32xyz( particles->px[ id ], particles->py[ id ], particles->pz[ id ] );
    f32xyz dir = make_f32xyz( particles->dx[ id ], particles->dy[ id ], particles->dz[ id ] );

    // Change the frame to the particle (global to linac)
    pos = fxyz_global_to_local_position( linac->transform, pos );
    dir = fxyz_global_to_local_direction( linac->transform, dir );

    // Store data
    particles->px[ id ] = pos.x;
    particles->py[ id ] = pos.y;
    particles->pz[ id ] = pos.z;
    particles->dx[ id ] = dir.x;
    particles->dy[ id ] = dir.y;
    particles->dz[ id ] = dir.z;

    transport_track_to_in_AABB( particles, linac->aabb, geom_tolerance, id );

    // Start outside a mesh
    particles->geometry_id[ id ] = 0;  // first Byte set to zeros (outside a mesh)
}

// == Track to out ===================================================================================
/*
//            32   28   24   20   16   12   8    4
// geometry:  0000 0000 0000 0000 0000 0000 0000 0000
//            \__/ \____________/ \_________________/
//             |         |                 |
//            nav mesh  type of geometry  geometry index

__host__ __device__ ui16 m_read_geom_type( ui32 geometry )
{
    return ui16( ( geometry & 0x0FFF0000 ) >> 16 );
}

__host__ __device__ ui16 m_read_geom_index( ui32 geometry )
{
    return ui16( geometry & 0x0000FFFF );
}

__host__ __device__ ui8 m_read_geom_nav( ui32 geometry )
{
    return ui8( ( geometry & 0xF0000000 ) >> 28 );
}

__host__ __device__ ui32 m_write_geom_type( ui32 geometry, ui16 type )
{
    //              mask           write   shift
    return ( geometry & 0xF000FFFF ) | ( type << 16 ) ;
}

__host__ __device__ ui32 m_write_geom_index( ui32 geometry, ui16 index )
{
    //              mask           write   shift
    return ( geometry & 0xFFFF0000 ) | index ;
}

__host__ __device__ ui32 m_write_geom_nav( ui32 geometry, ui8 nav )
{
    //              mask           write   shift
    return ( geometry & 0x0FFFFFFF ) | ( nav << 28 ) ;
}
*/

__host__ __device__ void m_transport_mesh( f32xyz pos, f32xyz dir,
                                           const f32xyz *v1, const f32xyz *v2, const f32xyz *v3,
                                           ui32 offset, ui32 nb_tri,
                                           f32 geom_tol,
                                           ui8 *inside, ui8 *hit, f32 *distance )
{
    f32 cur_distance, tmin, tmax;

    tmin =  FLT_MAX;
    tmax = -FLT_MAX;

    // Loop over triangles
    ui32 itri = 0; while ( itri < nb_tri )
    {

        cur_distance = hit_ray_triangle( pos, dir, v1[ offset+itri ], v2[ offset+itri ], v3[ offset+itri ] );        

        tmin = ( cur_distance < tmin ) ? cur_distance : tmin;
        tmax = ( cur_distance > tmax && cur_distance != FLT_MAX ) ? cur_distance : tmax;
//        tmax = ( cur_distance > tmax ) ? cur_distance : tmax;
        ++itri;
    }   

    // Analyse tmin and tmax

    //   tmin = tmax = 0
    // -------(+)------>
    //       (   )
    if ( tmin < 0.0 && tmin > -geom_tol && tmax > 0.0 && tmax < geom_tol  )
    {
        *inside = false;
        *hit = false;
        *distance = FLT_MAX;
        return;
    }

    //
    //  tmin +inf   tmax -inf
    //
    // ---+----->
    //
    //  (     )
    if ( tmin > 0.0 && tmax < 0.0 )
    {
        *inside = false;
        *hit = false;
        *distance = FLT_MAX;
        return;
    }

    //    tmin       tmax
    //  ----(----+----)--->
    if ( tmin < 0.0 && tmax > 0.0 )
    {
        *inside = true;
        *hit = true;
        *distance = tmax;
        return;
    }

    //      tmin   tmax
    // --+---(------)--->
    if ( tmin > 0.0 && tmax > 0.0 )
    {
        *inside = false;
        *hit = true;
        *distance = tmin;
        return;
    }

    //     tmin   tmax
    // -----(-------)--+--->
    if ( tmin < 0.0 && tmax < 0.0 )
    {
        *inside = false;
        *hit = false;
        *distance = FLT_MAX;
        return;
    }

}

// Raytracing within the LINAC head
__host__ __device__ void m_raytracing_linac( f32xyz pos, f32xyz dir, const LinacData *linac, f32 geom_tol,
                                             ui16 *geom_id, f32 *distance )
{
    ui8 hit_mesh[1];
    hit_mesh[0] = false;

    f32 hit_distance[1];
    hit_distance[0] = FLT_MAX;

    ui8 flag_inside_mesh[1];
    flag_inside_mesh[0] = false;
    ui32 ileaf;

    *geom_id = IN_NOTHING;
    *distance = hit_ray_AABB( pos, dir, linac->aabb );

    // X-Jaw
    if ( linac->X_nb_jaw != 0 )
    {
        pos = transport_get_safety_outside_AABB( pos, linac->X_jaw_aabb[ 0 ], geom_tol );
        // First check the bounding box
        if ( test_point_AABB( pos, linac->X_jaw_aabb[ 0 ] ) )
        {
            // Then the mesh
            m_transport_mesh( pos, dir, linac->X_jaw_v1, linac->X_jaw_v2, linac->X_jaw_v3,
                              linac->X_jaw_index[ 0 ], linac->X_jaw_nb_triangles[ 0 ], geom_tol,
                              flag_inside_mesh, hit_mesh, hit_distance );

            // inside the mesh
            if ( *flag_inside_mesh == INSIDE_MESH )
            {
                *geom_id = IN_JAW_X1;
                *distance = *hit_distance;
                return;
            }
            // not inside but the trajectory will hit the mesh
            else if ( hit_mesh )
            {
                if ( *hit_distance < *distance ) *distance = *hit_distance;
            }
            // not inside and the trajectory will not hit the mesh, then return the AABB distance
            else
            {
                *hit_distance = hit_ray_AABB( pos, dir, linac->X_jaw_aabb[ 0 ] );
                if ( *hit_distance < *distance ) *distance = *hit_distance;
            }
        }
        // Not inside the AABB, get the distance to in
        else
        {
            *hit_distance = hit_ray_AABB( pos, dir, linac->X_jaw_aabb[ 0 ] );
            if ( *hit_distance < *distance ) *distance = *hit_distance;
        }

        pos = transport_get_safety_outside_AABB( pos, linac->X_jaw_aabb[ 1 ], geom_tol );
        if ( test_point_AABB( pos, linac->X_jaw_aabb[ 1 ] ) )
        {
            m_transport_mesh( pos, dir, linac->X_jaw_v1, linac->X_jaw_v2, linac->X_jaw_v3,
                              linac->X_jaw_index[ 1 ], linac->X_jaw_nb_triangles[ 1 ], geom_tol,
                              flag_inside_mesh, hit_mesh, hit_distance );

            // inside the mesh
            if ( *flag_inside_mesh == INSIDE_MESH )
            {
                *geom_id = IN_JAW_X2;
                *distance = *hit_distance;
                return;
            }
            // not inside but the trajectory will hit the mesh
            else if ( hit_mesh )
            {
                if ( *hit_distance < *distance ) *distance = *hit_distance;
            }
            // not inside and the trajectory will not hit the mesh, then return the AABB distance
            else
            {
                *hit_distance = hit_ray_AABB( pos, dir, linac->X_jaw_aabb[ 1 ] );
                if ( *hit_distance < *distance ) *distance = *hit_distance;
            }
        }
        // Not inside the AABB, get the distance to in
        else
        {
            *hit_distance = hit_ray_AABB( pos, dir, linac->X_jaw_aabb[ 1 ] );
            if ( *hit_distance < *distance ) *distance = *hit_distance;
        }
    }

    // Y-Jaw
    if ( linac->Y_nb_jaw != 0 )
    {
        pos = transport_get_safety_outside_AABB( pos, linac->Y_jaw_aabb[ 0 ], geom_tol );
        if ( test_point_AABB( pos, linac->Y_jaw_aabb[ 0 ] ) )
        {
            m_transport_mesh( pos, dir, linac->Y_jaw_v1, linac->Y_jaw_v2, linac->Y_jaw_v3,
                              linac->Y_jaw_index[ 0 ], linac->Y_jaw_nb_triangles[ 0 ], geom_tol,
                              flag_inside_mesh, hit_mesh, hit_distance );

            // inside the mesh
            if ( *flag_inside_mesh == INSIDE_MESH )
            {
                *geom_id = IN_JAW_Y1;
                *distance = *hit_distance;
                return;
            }
            // not inside but the trajectory will hit the mesh
            else if ( hit_mesh )
            {
                if ( *hit_distance < *distance ) *distance = *hit_distance;
            }
            // not inside and the trajectory will not hit the mesh, then return the AABB distance
            else
            {
                *hit_distance = hit_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 0 ] );
                if ( *hit_distance < *distance ) *distance = *hit_distance;
            }
        }
        // Not inside the AABB, get the distance to in
        else
        {
            *hit_distance = hit_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 0 ] );
            if ( *hit_distance < *distance ) *distance = *hit_distance;
        }

        pos = transport_get_safety_outside_AABB( pos, linac->Y_jaw_aabb[ 1 ], geom_tol );
        if ( test_point_AABB( pos, linac->Y_jaw_aabb[ 1 ] ) )
        {
            m_transport_mesh( pos, dir, linac->Y_jaw_v1, linac->Y_jaw_v2, linac->Y_jaw_v3,
                              linac->Y_jaw_index[ 1 ], linac->Y_jaw_nb_triangles[ 1 ], geom_tol,
                              flag_inside_mesh, hit_mesh, hit_distance );

            // inside the mesh
            if ( *flag_inside_mesh == INSIDE_MESH )
            {
                *geom_id = IN_JAW_Y2;
                *distance = *hit_distance;
                return;
            }
            // not inside but the trajectory will hit the mesh
            else if ( hit_mesh )
            {
                if ( *hit_distance < *distance ) *distance = *hit_distance;
            }
            // not inside and the trajectory will not hit the mesh, then return the AABB distance
            else
            {
                *hit_distance = hit_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 1 ] );
                if ( *hit_distance < *distance ) *distance = *hit_distance;
            }
        }
        // Not inside the AABB, get the distance to in
        else
        {
            *hit_distance = hit_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 1 ] );
            if ( *hit_distance < *distance ) *distance = *hit_distance;
        }
    }

    // Bank A
    pos = transport_get_safety_outside_AABB( pos, linac->A_bank_aabb, geom_tol );
    if ( test_point_AABB( pos, linac->A_bank_aabb ) )
    {
        // Loop over leaves
        ileaf = 0; while( ileaf < linac->A_nb_leaves )
        {
            // If hit a leaf bounding box
            if ( test_ray_AABB( pos, dir, linac->A_leaf_aabb[ ileaf ] ) )
            {
                m_transport_mesh( pos, dir, linac->A_leaf_v1, linac->A_leaf_v2, linac->A_leaf_v3,
                                  linac->A_leaf_index[ ileaf ], linac->A_leaf_nb_triangles[ ileaf ], geom_tol,
                                  flag_inside_mesh, hit_mesh, hit_distance );

                // If already inside of one of them
                if ( *flag_inside_mesh )
                {
                    *geom_id = IN_BANK_A;
                    *distance = *hit_distance;
                    return;
                }
                // not inside but the trajectory will hit the mesh
                else if ( hit_mesh )
                {
                    if ( *hit_distance < *distance ) *distance = *hit_distance;
                }
                // not inside and the trajectory will not hit the mesh, then return the AABB distance
                else
                {
                    *hit_distance = hit_ray_AABB( pos, dir, linac->A_leaf_aabb[ ileaf ] );
                    if ( *hit_distance < *distance ) *distance = *hit_distance;
                }
            } // in a leaf bounding box
            else
            {
                *hit_distance = hit_ray_AABB( pos, dir, linac->A_leaf_aabb[ ileaf ] );
                if ( *hit_distance < *distance ) *distance = *hit_distance;
            }

            ++ileaf;
        } // each leaf
    }
    // Not inside the AABB, get the distance to in
    else
    {
        *hit_distance = hit_ray_AABB( pos, dir, linac->A_bank_aabb );
        if ( *hit_distance < *distance ) *distance = *hit_distance;
    }

    // Bank B
    pos = transport_get_safety_outside_AABB( pos, linac->B_bank_aabb, geom_tol );
    if ( test_point_AABB( pos, linac->B_bank_aabb ) )
    {
        // Loop over leaves
        ileaf = 0; while( ileaf < linac->B_nb_leaves )
        {
            // If hit a leaf bounding box
            if ( test_ray_AABB( pos, dir, linac->B_leaf_aabb[ ileaf ] ) )
            {
                m_transport_mesh( pos, dir, linac->B_leaf_v1, linac->B_leaf_v2, linac->B_leaf_v3,
                                  linac->B_leaf_index[ ileaf ], linac->B_leaf_nb_triangles[ ileaf ], geom_tol,
                                  flag_inside_mesh, hit_mesh, hit_distance );

                // If already inside of one of them
                if ( *flag_inside_mesh )
                {
                    *geom_id = IN_BANK_B;
                    *distance = *hit_distance;
                    return;
                }
                // not inside but the trajectory will hit the mesh
                else if ( hit_mesh )
                {
                    if ( *hit_distance < *distance ) *distance = *hit_distance;
                }
                // not inside and the trajectory will not hit the mesh, then return the AABB distance
                else
                {
                    *hit_distance = hit_ray_AABB( pos, dir, linac->B_leaf_aabb[ ileaf ] );
                    if ( *hit_distance < *distance ) *distance = *hit_distance;
                }
            } // in a leaf bounding box
            else
            {
                *hit_distance = hit_ray_AABB( pos, dir, linac->B_leaf_aabb[ ileaf ] );
                if ( *hit_distance < *distance ) *distance = *hit_distance;
            }

            ++ileaf;
        } // each leaf
    }
    // Not inside the AABB, get the distance to in
    else
    {
        *hit_distance = hit_ray_AABB( pos, dir, linac->B_bank_aabb );
        if ( *hit_distance < *distance ) *distance = *hit_distance;
    }

    // If not already return, it's mean that the particle is outside

}

// Raytracing within the LINAC head by considering only bounding box
__host__ __device__ void m_raytracing_AABB_linac( f32xyz pos, f32xyz dir, const LinacData *linac, f32 geom_tol,
                                                  ui16 *geom_id, f32 *distance )
{

    f32 hit_distance[1];
    hit_distance[0] = FLT_MAX;
    ui32 ileaf;

    *geom_id = IN_NOTHING;
    *distance = hit_ray_AABB( pos, dir, linac->aabb );

    // X-Jaw
    if ( linac->X_nb_jaw != 0 )
    {
        pos = transport_get_safety_outside_AABB( pos, linac->X_jaw_aabb[ 0 ], geom_tol );
        if ( test_point_AABB( pos, linac->X_jaw_aabb[ 0 ] ) )
        {
            *geom_id = IN_JAW_X1;
            *distance = hit_ray_AABB( pos, dir, linac->X_jaw_aabb[ 0 ] );
            return;
        }
        else
        {
            *hit_distance = hit_ray_AABB( pos, dir, linac->X_jaw_aabb[ 0 ] );
            if ( *hit_distance < *distance ) *distance = *hit_distance;
        }

        pos = transport_get_safety_outside_AABB( pos, linac->X_jaw_aabb[ 1 ], geom_tol );
        if ( test_point_AABB( pos, linac->X_jaw_aabb[ 1 ] ) )
        {
            *geom_id = IN_JAW_X2;
            *distance = hit_ray_AABB( pos, dir, linac->X_jaw_aabb[ 1 ] );
            return;
        }
        else
        {
            *hit_distance = hit_ray_AABB( pos, dir, linac->X_jaw_aabb[ 1 ] );
            if ( *hit_distance < *distance ) *distance = *hit_distance;
        }
    }

    // Y-Jaw
    if ( linac->Y_nb_jaw != 0 )
    {
        pos = transport_get_safety_outside_AABB( pos, linac->Y_jaw_aabb[ 0 ], geom_tol );
        if ( test_point_AABB( pos, linac->Y_jaw_aabb[ 0 ] ) )
        {
            *geom_id = IN_JAW_Y1;
            *distance = hit_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 0 ] );
            return;
        }
        else
        {
            *hit_distance = hit_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 0 ] );
            if ( *hit_distance < *distance ) *distance = *hit_distance;
        }

        pos = transport_get_safety_outside_AABB( pos, linac->Y_jaw_aabb[ 1 ], geom_tol );
        if ( test_point_AABB( pos, linac->Y_jaw_aabb[ 1 ] ) )
        {
            *geom_id = IN_JAW_Y2;
            *distance = hit_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 1 ] );
            return;
        }
        else
        {
            *hit_distance = hit_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 1 ] );
            if ( *hit_distance < *distance ) *distance = *hit_distance;
        }
    }

    // Bank A
    pos = transport_get_safety_outside_AABB( pos, linac->A_bank_aabb, geom_tol );
    if ( test_point_AABB( pos, linac->A_bank_aabb ) )
    {
        // Loop over leaves
        ileaf = 0; while( ileaf < linac->A_nb_leaves )
        {
            // If hit a leaf bounding box
            if ( test_ray_AABB( pos, dir, linac->A_leaf_aabb[ ileaf ] ) )
            {
                *geom_id = IN_BANK_A;
                *distance = hit_ray_AABB( pos, dir, linac->A_leaf_aabb[ ileaf ] );
                return;
            } // in a leaf bounding box
            else
            {
                *hit_distance = hit_ray_AABB( pos, dir, linac->A_leaf_aabb[ ileaf ] );
                if ( *hit_distance < *distance ) *distance = *hit_distance;
            }

            ++ileaf;
        } // each leaf
    }
    // Not inside the AABB, get the distance to in
    else
    {
        *hit_distance = hit_ray_AABB( pos, dir, linac->A_bank_aabb );
        if ( *hit_distance < *distance ) *distance = *hit_distance;
    }

    // Bank B
    pos = transport_get_safety_outside_AABB( pos, linac->B_bank_aabb, geom_tol );
    if ( test_point_AABB( pos, linac->B_bank_aabb ) )
    {
        // Loop over leaves
        ileaf = 0; while( ileaf < linac->B_nb_leaves )
        {
            // If hit a leaf bounding box
            if ( test_ray_AABB( pos, dir, linac->B_leaf_aabb[ ileaf ] ) )
            {
                *geom_id = IN_BANK_B;
                *distance = hit_ray_AABB( pos, dir, linac->B_leaf_aabb[ ileaf ] );
                return;
            } // in a leaf bounding box
            else
            {
                *hit_distance = hit_ray_AABB( pos, dir, linac->B_leaf_aabb[ ileaf ] );
                if ( *hit_distance < *distance ) *distance = *hit_distance;
            }

            ++ileaf;
        } // each leaf
    }
    // Not inside the AABB, get the distance to in
    else
    {
        *hit_distance = hit_ray_AABB( pos, dir, linac->B_bank_aabb );
        if ( *hit_distance < *distance ) *distance = *hit_distance;
    }
    // If not already return, it's mean that the particle is outside


}

/*
__host__ __device__ void m_mlc_nav_out_mesh( f32xyz pos, f32xyz dir, const LinacData *linac,
                                             f32 geom_tol,
                                             ui32 *geometry_id, f32 *geometry_distance )
{    
    // First check where is the particle /////////////////////////////////////////////////////

    ui16 in_obj = IN_NOTHING;

    if ( linac->X_nb_jaw != 0 )
    {
        pos = transport_get_safety_outside_AABB( pos, linac->X_jaw_aabb[ 0 ], geom_tol );
        if ( test_point_AABB( pos, linac->X_jaw_aabb[ 0 ] ) )
        {
            in_obj = IN_JAW_X1;
        }
        pos = transport_get_safety_outside_AABB( pos, linac->X_jaw_aabb[ 1 ], geom_tol );
        if ( test_point_AABB( pos, linac->X_jaw_aabb[ 1 ] ) )
        {
            in_obj = IN_JAW_X2;
        }
    }

    if ( linac->Y_nb_jaw != 0 )
    {
        pos = transport_get_safety_outside_AABB( pos, linac->Y_jaw_aabb[ 0 ], geom_tol );
        if ( test_point_AABB( pos, linac->Y_jaw_aabb[ 0 ] ) )
        {
            in_obj = IN_JAW_Y1;
        }
        pos = transport_get_safety_outside_AABB( pos, linac->Y_jaw_aabb[ 1 ], geom_tol );
        if ( test_point_AABB( pos, linac->Y_jaw_aabb[ 1 ] ) )
        {
            in_obj = IN_JAW_Y2;
        }
    }

    pos = transport_get_safety_outside_AABB( pos, linac->A_bank_aabb, geom_tol );
    if ( test_point_AABB( pos, linac->A_bank_aabb ) )
    {
        in_obj = IN_BANK_A;
    }

    pos = transport_get_safety_outside_AABB( pos, linac->B_bank_aabb, geom_tol );
    if ( test_point_AABB( pos, linac->B_bank_aabb ) )
    {
        in_obj = IN_BANK_B;
    }

    // If the particle is outside the MLC element, then get the clostest bounding box //////////

    *geometry_distance = FLT_MAX;  

    f32 distance = FLT_MAX;

    if ( in_obj == IN_NOTHING )
    {
        // Mother volume (AABB of the LINAC)
        *geometry_distance = hit_ray_AABB( pos, dir, linac->aabb );

        if ( linac->X_nb_jaw != 0 )
        {
            distance = hit_ray_AABB( pos, dir, linac->X_jaw_aabb[ 0 ] );
            if ( distance < *geometry_distance )
            {
                *geometry_distance = distance;
            }

            distance = hit_ray_AABB( pos, dir, linac->X_jaw_aabb[ 1 ] );
            if ( distance < *geometry_distance )
            {
                *geometry_distance = distance;
            }
        }

        if ( linac->Y_nb_jaw != 0 )
        {
            distance = hit_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 0 ] );
            if ( distance < *geometry_distance )
            {
                *geometry_distance = distance;
            }

            distance = hit_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 1 ] );
            if ( distance < *geometry_distance )
            {
                *geometry_distance = distance;
            }
        }

        distance = hit_ray_AABB( pos, dir, linac->A_bank_aabb );
        if ( distance < *geometry_distance )
        {
            *geometry_distance = distance;
        }

        distance = hit_ray_AABB( pos, dir, linac->B_bank_aabb );
        if ( distance < *geometry_distance )
        {
            *geometry_distance = distance;
        }

        // Store data and return
        *geometry_id = m_write_geom_nav( *geometry_id, OUTSIDE_MESH );
        *geometry_id = m_write_geom_type( *geometry_id, in_obj );

        return;
    }

    // Else, particle within a bounding box, need to get the closest distance to the mesh

    else
    {
        ui32 ileaf;
        ui8 inside_mesh = false;
        ui8 hit_mesh = false;
        i16 geom_index = -1;
        *geometry_distance = FLT_MAX;

        if ( in_obj == IN_JAW_X1 )
        {
            m_transport_mesh( pos, dir, linac->X_jaw_v1, linac->X_jaw_v2, linac->X_jaw_v3,
                              linac->X_jaw_index[ 0 ], linac->X_jaw_nb_triangles[ 0 ], geom_tol,
                              &inside_mesh, &hit_mesh, &distance );

            // If already inside the mesh
            if ( inside_mesh )
            {
                *geometry_id = m_write_geom_nav( *geometry_id, INSIDE_MESH );
                *geometry_id = m_write_geom_type( *geometry_id, IN_JAW_X1 );
                *geometry_distance = 0.0;
                return;
            }
            else if ( hit_mesh ) // Outside and hit the mesh
            {
                *geometry_id = m_write_geom_nav( *geometry_id, INSIDE_MESH );
                *geometry_id = m_write_geom_type( *geometry_id, IN_JAW_X1 );
                *geometry_distance = distance;
                return;
            }
            else // Not inside not hitting (then get the AABB distance)
            {
                *geometry_id = m_write_geom_nav( *geometry_id, OUTSIDE_MESH );
                *geometry_id = m_write_geom_type( *geometry_id, IN_NOTHING );
                *geometry_distance = hit_ray_AABB( pos, dir, linac->X_jaw_aabb[ 0 ] );
                return;
            }
        }

        if ( in_obj == IN_JAW_X2 )
        {
            m_transport_mesh( pos, dir, linac->X_jaw_v1, linac->X_jaw_v2, linac->X_jaw_v3,
                              linac->X_jaw_index[ 1 ], linac->X_jaw_nb_triangles[ 1 ], geom_tol,
                              &inside_mesh, &hit_mesh, &distance );

            // If already inside the mesh
            if ( inside_mesh )
            {
                *geometry_id = m_write_geom_nav( *geometry_id, INSIDE_MESH );
                *geometry_id = m_write_geom_type( *geometry_id, IN_JAW_X2 );
                *geometry_distance = 0.0;
                return;
            }
            else if ( hit_mesh ) // Outside and hit the mesh
            {
                *geometry_id = m_write_geom_nav( *geometry_id, INSIDE_MESH );
                *geometry_id = m_write_geom_type( *geometry_id, IN_JAW_X2 );
                *geometry_distance = distance;
                return;
            }
            else // Not inside not hitting (then get the AABB distance)
            {
                *geometry_id = m_write_geom_nav( *geometry_id, OUTSIDE_MESH );
                *geometry_id = m_write_geom_type( *geometry_id, IN_NOTHING );
                *geometry_distance = hit_ray_AABB( pos, dir, linac->X_jaw_aabb[ 1 ] );
                return;
            }
        }

        if ( in_obj == IN_JAW_Y1 )
        {            
            m_transport_mesh( pos, dir, linac->Y_jaw_v1, linac->Y_jaw_v2, linac->Y_jaw_v3,
                              linac->Y_jaw_index[ 0 ], linac->Y_jaw_nb_triangles[ 0 ], geom_tol,
                              &inside_mesh, &hit_mesh, &distance );            

            // If already inside the mesh
            if ( inside_mesh )
            {                
                *geometry_id = m_write_geom_nav( *geometry_id, INSIDE_MESH );                
                *geometry_id = m_write_geom_type( *geometry_id, IN_JAW_Y1 );                
                *geometry_distance = 0.0;

                return;
            }
            else if ( hit_mesh ) // Outside and hit the mesh
            {
                *geometry_id = m_write_geom_nav( *geometry_id, INSIDE_MESH );
                *geometry_id = m_write_geom_type( *geometry_id, IN_JAW_Y1 );
                *geometry_distance = distance;

                return;
            }
            else // Not inside not hitting (then get the AABB distance)
            {
                *geometry_id = m_write_geom_nav( *geometry_id, OUTSIDE_MESH );
                *geometry_id = m_write_geom_type( *geometry_id, IN_NOTHING );
                *geometry_distance = hit_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 0 ] );
                return;
            }
        }

        if ( in_obj == IN_JAW_Y2 )
        {
            m_transport_mesh( pos, dir, linac->Y_jaw_v1, linac->Y_jaw_v2, linac->Y_jaw_v3,
                              linac->Y_jaw_index[ 1 ], linac->Y_jaw_nb_triangles[ 1 ], geom_tol,
                              &inside_mesh, &hit_mesh, &distance );

            // If already inside the mesh
            if ( inside_mesh )
            {
                *geometry_id = m_write_geom_nav( *geometry_id, INSIDE_MESH );
                *geometry_id = m_write_geom_type( *geometry_id, IN_JAW_Y2 );
                *geometry_distance = 0.0;
                return;
            }
            else if ( hit_mesh ) // Outside and hit the mesh
            {
                *geometry_id = m_write_geom_nav( *geometry_id, INSIDE_MESH );
                *geometry_id = m_write_geom_type( *geometry_id, IN_JAW_Y2 );
                *geometry_distance = distance;
                return;
            }
            else // Not inside not hitting (then get the AABB distance)
            {
                *geometry_id = m_write_geom_nav( *geometry_id, OUTSIDE_MESH );
                *geometry_id = m_write_geom_type( *geometry_id, IN_NOTHING );
                *geometry_distance = hit_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 1 ] );
                return;
            }
        }

        if ( in_obj == IN_BANK_A )
        {
            // Loop over leaves
            ileaf = 0; while( ileaf < linac->A_nb_leaves )
            {
                // If hit a leaf bounding box
                if ( test_ray_AABB( pos, dir, linac->A_leaf_aabb[ ileaf ] ) )
                {

                    m_transport_mesh( pos, dir, linac->A_leaf_v1, linac->A_leaf_v2, linac->A_leaf_v3,
                                      linac->A_leaf_index[ ileaf ], linac->A_leaf_nb_triangles[ ileaf ], geom_tol,
                                      &inside_mesh, &hit_mesh, &distance );

                    // If already inside of one of them
                    if ( inside_mesh )
                    {
                        *geometry_id = m_write_geom_nav( *geometry_id, INSIDE_MESH );
                        *geometry_id = m_write_geom_type( *geometry_id, IN_BANK_A );
                        *geometry_id = m_write_geom_index( *geometry_id, ileaf );
                        *geometry_distance = 0.0;
                        return;
                    }
                    else if ( hit_mesh )
                    {
                        // Select the closest
                        if ( distance < *geometry_distance )
                        {
                            *geometry_distance = distance;
                            geom_index = ileaf;
                        }
                    }

                } // in a leaf bounding box

                ++ileaf;

            } // each leaf

            // No leaves were hit
            if ( geom_index < 0 )
            {
                *geometry_id = m_write_geom_nav( *geometry_id, OUTSIDE_MESH );
                *geometry_id = m_write_geom_type( *geometry_id, IN_NOTHING );
                *geometry_id = m_write_geom_index( *geometry_id, 0 );
                *geometry_distance = hit_ray_AABB( pos, dir, linac->A_bank_aabb ); // Bounding box
            }
            else
            {
                *geometry_id = m_write_geom_nav( *geometry_id, INSIDE_MESH );
                *geometry_id = m_write_geom_type( *geometry_id, IN_BANK_A );
                *geometry_id = m_write_geom_index( *geometry_id, ui16( geom_index ) );
            }

            return;
        }

        if ( in_obj == IN_BANK_B )
        {
            // Loop over leaves
            ileaf = 0; while( ileaf < linac->B_nb_leaves )
            {
                // If hit a leaf bounding box
                if ( test_ray_AABB( pos, dir, linac->B_leaf_aabb[ ileaf ] ) )
                {

                    m_transport_mesh( pos, dir, linac->B_leaf_v1, linac->B_leaf_v2, linac->B_leaf_v3,
                                      linac->B_leaf_index[ ileaf ], linac->B_leaf_nb_triangles[ ileaf ], geom_tol,
                                      &inside_mesh, &hit_mesh, &distance );

                    // If already inside of one of them
                    if ( inside_mesh )
                    {
                        *geometry_id = m_write_geom_nav( *geometry_id, INSIDE_MESH );
                        *geometry_id = m_write_geom_type( *geometry_id, IN_BANK_B );
                        *geometry_id = m_write_geom_index( *geometry_id, ileaf );
                        *geometry_distance = 0.0;
                        return;
                    }
                    else if ( hit_mesh )
                    {
                        // Select the closest
                        if ( distance < *geometry_distance )
                        {
                            *geometry_distance = distance;
                            geom_index = ileaf;
                        }
                    }

                } // in a leaf bounding box

                ++ileaf;

            } // each leaf

            // No leaves were hit
            if ( geom_index < 0 )
            {
                *geometry_id = m_write_geom_nav( *geometry_id, OUTSIDE_MESH );
                *geometry_id = m_write_geom_type( *geometry_id, IN_NOTHING );
                *geometry_id = m_write_geom_index( *geometry_id, 0 );
                *geometry_distance = hit_ray_AABB( pos, dir, linac->B_bank_aabb ); // Bounding box
            }
            else
            {
                *geometry_id = m_write_geom_nav( *geometry_id, INSIDE_MESH );
                *geometry_id = m_write_geom_type( *geometry_id, IN_BANK_B );
                *geometry_id = m_write_geom_index( *geometry_id, ui16( geom_index ) );
            }

            return;
        }

    }


    // Should never reach here
#ifdef DEBUG
    printf("MLC navigation error: out of geometry\n");
#endif

}

__host__ __device__ void m_mlc_nav_in_mesh( f32xyz pos, f32xyz dir, const LinacData *linac,
                                            f32 geom_tol,
                                            ui32 *geometry_id, f32 *geometry_distance )
{   
    // Read the geometry
    ui16 in_obj = m_read_geom_type( *geometry_id );

    ui8 inside_mesh = false;
    ui8 hit_mesh = false;
    f32 distance;

    if ( in_obj == IN_JAW_X1 )
    {
        m_transport_mesh( pos, dir, linac->X_jaw_v1, linac->X_jaw_v2, linac->X_jaw_v3,
                          linac->X_jaw_index[ 0 ], linac->X_jaw_nb_triangles[ 0 ], geom_tol,
                          &inside_mesh, &hit_mesh, &distance );

        // If not inside (in case of crossing a tiny piece of matter get the AABB distance)
        *geometry_distance = ( inside_mesh ) ? distance : hit_ray_AABB( pos, dir, linac->X_jaw_aabb[ 0 ] );
    }

    else if ( in_obj == IN_JAW_X2 )
    {
        m_transport_mesh( pos, dir, linac->X_jaw_v1, linac->X_jaw_v2, linac->X_jaw_v3,
                          linac->X_jaw_index[ 1 ], linac->X_jaw_nb_triangles[ 1 ], geom_tol,
                          &inside_mesh, &hit_mesh, &distance );

        // If not inside (in case of crossing a tiny piece of matter get the AABB distance)
        *geometry_distance = ( inside_mesh ) ? distance : hit_ray_AABB( pos, dir, linac->X_jaw_aabb[ 1 ] );
    }

    else if ( in_obj == IN_JAW_Y1 )
    {
        m_transport_mesh( pos, dir, linac->Y_jaw_v1, linac->Y_jaw_v2, linac->Y_jaw_v3,
                          linac->Y_jaw_index[ 0 ], linac->Y_jaw_nb_triangles[ 0 ], geom_tol,
                          &inside_mesh, &hit_mesh, &distance );

        // If not inside (in case of crossing a tiny piece of matter get the AABB distance)
        *geometry_distance = ( inside_mesh ) ? distance : hit_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 0 ] );
    }

    else if ( in_obj == IN_JAW_Y2 )
    {
        m_transport_mesh( pos, dir, linac->Y_jaw_v1, linac->Y_jaw_v2, linac->Y_jaw_v3,
                          linac->Y_jaw_index[ 1 ], linac->Y_jaw_nb_triangles[ 1 ], geom_tol,
                          &inside_mesh, &hit_mesh, &distance );

        // If not inside (in case of crossing a tiny piece of matter get the AABB distance)
        *geometry_distance = ( inside_mesh ) ? distance : hit_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 1 ] );
    }

    else if ( in_obj == IN_BANK_A )
    {
        ui16 ileaf = m_read_geom_index( *geometry_id );

        m_transport_mesh( pos, dir, linac->A_leaf_v1, linac->A_leaf_v2, linac->A_leaf_v3,
                          linac->A_leaf_index[ ileaf ], linac->A_leaf_nb_triangles[ ileaf ], geom_tol,
                          &inside_mesh, &hit_mesh, &distance );

        // If not inside (in case of crossing a tiny piece of matter get the AABB distance)
        *geometry_distance = ( inside_mesh ) ? distance : hit_ray_AABB( pos, dir, linac->A_leaf_aabb[ ileaf ] );
    }

    else if ( in_obj == IN_BANK_B )
    {
        ui16 ileaf = m_read_geom_index( *geometry_id );

        m_transport_mesh( pos, dir, linac->B_leaf_v1, linac->B_leaf_v2, linac->B_leaf_v3,
                          linac->B_leaf_index[ ileaf ], linac->B_leaf_nb_triangles[ ileaf ], geom_tol,
                          &inside_mesh, &hit_mesh, &distance );

        // If not inside (in case of crossing a tiny piece of matter get the AABB distance)
        *geometry_distance = ( inside_mesh ) ? distance : hit_ray_AABB( pos, dir, linac->B_leaf_aabb[ ileaf ] );
    }

    else
    {
        // Should never reach here
        #ifdef DEBUG
            printf("MLC navigation error: out of geometry\n");
        #endif
    }

    *geometry_id = m_write_geom_nav( *geometry_id, OUTSIDE_MESH );
    *geometry_id = m_write_geom_type( *geometry_id, IN_NOTHING );
    return;

}
*/

__host__ __device__ void MPLINACN::track_to_out( ParticlesData *particles,
                                                 const LinacData *linac,
                                                 const MaterialsData *materials,
                                                 const PhotonCrossSectionData *photon_CS_table,
                                                 const GlobalSimulationParametersData *parameters,
                                                 ui32 id )
{
    // Read position
    f32xyz pos;
    pos.x = particles->px[ id ];
    pos.y = particles->py[ id ];
    pos.z = particles->pz[ id ];

    // Read direction
    f32xyz dir;
    dir.x = particles->dx[ id ];
    dir.y = particles->dy[ id ];
    dir.z = particles->dz[ id ];

    // Where is the particle? Distance of the next boundary?
    ui16 geom_id[1];
    geom_id[0] = IN_NOTHING;
    f32 boundary_distance[1];
    boundary_distance[0] = F32_MAX;

    m_raytracing_linac( pos, dir, linac, parameters->geom_tolerance,
                        geom_id, boundary_distance );

    //// Get material //////////////////////////////////////////////////////////////////

    i16 mat_id = ( *geom_id == IN_NOTHING ) ? -1 : 0;   // -1 not mat around the LINAC (vacuum), 0 MLC mat

    //// Find next discrete interaction ///////////////////////////////////////

    f32 next_interaction_distance = F32_MAX;
    ui8 next_discrete_process = 0;

    // If inside a mesh do physics else only tranportation (vacuum around the LINAC)
    if ( mat_id != - 1 )
    {
        photon_get_next_interaction ( particles, parameters, photon_CS_table, mat_id, id );
        next_interaction_distance = particles->next_interaction_distance[ id ];
        next_discrete_process = particles->next_discrete_process[ id ];
    }

    /// Get the hit distance of the closest geometry //////////////////////////////////

    if ( *boundary_distance <= next_interaction_distance )
    {
        next_interaction_distance = *boundary_distance + parameters->geom_tolerance; // Overshoot
        next_discrete_process = GEOMETRY_BOUNDARY;
    }

    //// Move particle //////////////////////////////////////////////////////

    // get the new position
    pos = fxyz_add ( pos, fxyz_scale ( dir, next_interaction_distance ) );

    // update tof
    //particles->tof[part_id] += c_light * next_interaction_distance;

    // store new position
    particles->px[ id ] = pos.x;
    particles->py[ id ] = pos.y;
    particles->pz[ id ] = pos.z;

    // Stop simulation if out of the phantom
    if ( !test_point_AABB_with_tolerance ( pos, linac->aabb, parameters->geom_tolerance ) )
    {
        particles->status[ id ] = PARTICLE_FREEZE;
        return;
    }

    //// Apply discrete process //////////////////////////////////////////////////

    if ( next_discrete_process != GEOMETRY_BOUNDARY )
    {
        // Resolve discrete process
        SecParticle electron = photon_resolve_discrete_process ( particles, parameters, photon_CS_table,
                                                                 materials, mat_id, id );

        //// Here e- are not tracked, and lost energy not drop
        //// Energy cut
        if ( particles->E[ id ] <= materials->photon_energy_cut[ mat_id ])
        {
            // kill without mercy (energy not drop)
            particles->status[ id ] = PARTICLE_DEAD;
            return;
        }
    }   

}

__host__ __device__ void MPLINACN::track_to_out_nomesh( ParticlesData *particles,
                                                        const LinacData *linac,
                                                        const MaterialsData *materials,
                                                        const PhotonCrossSectionData *photon_CS_table,
                                                        const GlobalSimulationParametersData *parameters,
                                                        ui32 id )
{
    // Read position
    f32xyz pos;
    pos.x = particles->px[ id ];
    pos.y = particles->py[ id ];
    pos.z = particles->pz[ id ];

    // Read direction
    f32xyz dir;
    dir.x = particles->dx[ id ];
    dir.y = particles->dy[ id ];
    dir.z = particles->dz[ id ];

    // Where is the particle? Distance of the next boundary?
    ui16 geom_id[1];
    geom_id[0] = IN_NOTHING;
    f32 boundary_distance[1];
    boundary_distance[0] = F32_MAX;

    m_raytracing_AABB_linac( pos, dir, linac, parameters->geom_tolerance,
                             geom_id, boundary_distance );

    //// Get material //////////////////////////////////////////////////////////////////

    i16 mat_id = ( *geom_id == IN_NOTHING ) ? -1 : 0;   // -1 not mat around the LINAC (vacuum), 0 MLC mat

    //// Find next discrete interaction ///////////////////////////////////////

    f32 next_interaction_distance = F32_MAX;
    ui8 next_discrete_process = 0;

    // If inside a mesh do physics else only tranportation (vacuum around the LINAC)
    if ( mat_id != - 1 )
    {
        photon_get_next_interaction ( particles, parameters, photon_CS_table, mat_id, id );
        next_interaction_distance = particles->next_interaction_distance[ id ];
        next_discrete_process = particles->next_discrete_process[ id ];
    }

    /// Get the hit distance of the closest geometry //////////////////////////////////

    if ( *boundary_distance <= next_interaction_distance )
    {
        next_interaction_distance = *boundary_distance + parameters->geom_tolerance; // Overshoot
        next_discrete_process = GEOMETRY_BOUNDARY;
    }

    //// Move particle //////////////////////////////////////////////////////

    // get the new position
    pos = fxyz_add ( pos, fxyz_scale ( dir, next_interaction_distance ) );

    // update tof
    //particles->tof[part_id] += c_light * next_interaction_distance;

    // store new position
    particles->px[ id ] = pos.x;
    particles->py[ id ] = pos.y;
    particles->pz[ id ] = pos.z;

    // Stop simulation if out of the phantom
    if ( !test_point_AABB_with_tolerance ( pos, linac->aabb, parameters->geom_tolerance ) )
    {
        particles->status[ id ] = PARTICLE_FREEZE;
        return;
    }

    //// Apply discrete process //////////////////////////////////////////////////

    if ( next_discrete_process != GEOMETRY_BOUNDARY )
    {
        // Resolve discrete process
        SecParticle electron = photon_resolve_discrete_process ( particles, parameters, photon_CS_table,
                                                                 materials, mat_id, id );

        //// Here e- are not tracked, and lost energy not drop
        //// Energy cut
        if ( particles->E[ id ] <= materials->photon_energy_cut[ mat_id ])
        {
            // kill without mercy (energy not drop)
            particles->status[ id ] = PARTICLE_DEAD;
            return;
        }
    }

}

/*
__host__ __device__ void MPLINACN::track_to_out( ParticlesData *particles,
                                                 const LinacData *linac,
                                                 const MaterialsData *materials,
                                                 const PhotonCrossSectionData *photon_CS_table,
                                                 const GlobalSimulationParametersData *parameters,
                                                 ui32 id )
{
    // Read position
    f32xyz pos;
    pos.x = particles->px[ id ];
    pos.y = particles->py[ id ];
    pos.z = particles->pz[ id ];

    // Read direction
    f32xyz dir;
    dir.x = particles->dx[ id ];
    dir.y = particles->dy[ id ];
    dir.z = particles->dz[ id ];

    // In a mesh?
    ui8 navigation = m_read_geom_nav( particles->geometry_id[ id ] );

    //// Get material //////////////////////////////////////////////////////////////////

    i16 mat_id = ( navigation == INSIDE_MESH ) ? 0 : -1;   // 0 MLC mat, -1 not mat around the LINAC (vacuum)

    //// Find next discrete interaction ///////////////////////////////////////

    f32 next_interaction_distance = F32_MAX;
    ui8 next_discrete_process = 0;

    // If inside a mesh do physics else only tranportation (vacuum around the LINAC)
    if ( mat_id != - 1 )
    {
        photon_get_next_interaction ( particles, parameters, photon_CS_table, mat_id, id );
        next_interaction_distance = particles->next_interaction_distance[ id ];
        next_discrete_process = particles->next_discrete_process[ id ];
    }

    /// Get the hit distance of the closest geometry //////////////////////////////////

    f32 boundary_distance;
    ui32 next_geometry_id = particles->geometry_id[ id ];

//    if ( id == 30966 ) printf("ID %i  next_geom %x  nav %i   Proc %i DistInt %e\n", id, next_geometry_id, navigation, next_discrete_process, next_interaction_distance);

    if ( navigation == INSIDE_MESH )
    {
        m_mlc_nav_in_mesh( pos, dir, linac, parameters->geom_tolerance, &next_geometry_id, &boundary_distance );
//        if ( id == 30966 ) printf("   inside newstate next_geom %x dist %e\n", next_geometry_id, boundary_distance);
    }
    else
    {
        m_mlc_nav_out_mesh( pos, dir, linac, parameters->geom_tolerance, &next_geometry_id, &boundary_distance );
//        if ( id == 30966 ) printf("   outside newstate next_geom %x dist %e pos %f %f %f  dir %f %f %f  AABB %f %f %f %f %f %f\n", next_geometry_id, boundary_distance,
//                                  pos.x, pos.y, pos.z, dir.x, dir.y, dir.z,
//                                  linac->X_jaw_aabb[ 1 ].xmin, linac->X_jaw_aabb[ 1 ].xmax,
//                                  linac->X_jaw_aabb[ 1 ].ymin, linac->X_jaw_aabb[ 1 ].ymax,
//                                  linac->X_jaw_aabb[ 1 ].zmin, linac->X_jaw_aabb[ 1 ].zmax);
    }

    ui16 geom = m_read_geom_type(next_geometry_id);
    ui8 nav = m_read_geom_nav(next_geometry_id);


    if ( boundary_distance <= next_interaction_distance )
    {
        next_interaction_distance = boundary_distance + parameters->geom_tolerance; // Overshoot
        next_discrete_process = GEOMETRY_BOUNDARY;
    }

//    if ( id == 30966 ) printf("ID %i OUTNAV next_geom %i  nav %i   Proc %i  Dist %e\n", id, geom, nav, next_discrete_process, next_interaction_distance);

    //// Move particle //////////////////////////////////////////////////////

    // get the new position
    pos = fxyz_add ( pos, fxyz_scale ( dir, next_interaction_distance ) );

    // update tof
    //particles->tof[part_id] += c_light * next_interaction_distance;

    // store new position
    particles->px[ id ] = pos.x;
    particles->py[ id ] = pos.y;
    particles->pz[ id ] = pos.z;

    // Stop simulation if out of the phantom
    if ( !test_point_AABB_with_tolerance ( pos, linac->aabb, parameters->geom_tolerance ) )
    {
        particles->status[ id ] = PARTICLE_FREEZE;
        return;
    }

    //// Apply discrete process //////////////////////////////////////////////////

    if ( next_discrete_process != GEOMETRY_BOUNDARY )
    {
        // Resolve discrete process
        SecParticle electron = photon_resolve_discrete_process ( particles, parameters, photon_CS_table,
                                                                 materials, mat_id, id );

        //// Here e- are not tracked, and lost energy not drop
        //// Energy cut
        if ( particles->E[ id ] <= materials->photon_energy_cut[ mat_id ])
        {
            // kill without mercy (energy not drop)
            particles->status[ id ] = PARTICLE_DEAD;
//            printf("kill\n");
            return;
        }

//        if ( id == 30966 ) printf("proc\n");
    }
    else
    {
//        if ( id == 30966 ) printf("update\n");
        // Update geometry id
        particles->geometry_id[ id ] = next_geometry_id;

//        printf("partcile geom %x\n", particles->geometry_id[ id ]);
    }

}
*/

__host__ __device__ void MPLINACN::track_to_out_nonav( ParticlesData *particles, const LinacData *linac,
                                                       ui32 id )
{
    // Read position
    f32xyz pos;
    pos.x = particles->px[ id ];
    pos.y = particles->py[ id ];
    pos.z = particles->pz[ id ];

    // Read direction
    f32xyz dir;
    dir.x = particles->dx[ id ];
    dir.y = particles->dy[ id ];
    dir.z = particles->dz[ id ];

    /// Get the hit distance of the closest geometry //////////////////////////////////

    ui16 in_obj = HIT_NOTHING;
    ui32 itri, offset, ileaf;
    f32 geom_distance;
    f32 min_distance = FLT_MAX;

    // First get the distance to the bounding box

    if ( linac->X_nb_jaw != 0 )
    {
        geom_distance = hit_ray_AABB( pos, dir, linac->X_jaw_aabb[ 0 ] );
        if ( geom_distance < min_distance )
        {
            min_distance = geom_distance;
            in_obj = HIT_JAW_X1;
        }

        geom_distance = hit_ray_AABB( pos, dir, linac->X_jaw_aabb[ 1 ] );
        if ( geom_distance < min_distance )
        {
            min_distance = geom_distance;
            in_obj = HIT_JAW_X2;
        }
    }

    if ( linac->Y_nb_jaw != 0 )
    {
        geom_distance = hit_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 0 ] );
        if ( geom_distance < min_distance )
        {
            min_distance = geom_distance;
            in_obj = HIT_JAW_Y1;
        }

        geom_distance = hit_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 1 ] );
        if ( geom_distance < min_distance )
        {
            min_distance = geom_distance;
            in_obj = HIT_JAW_Y2;
        }
    }

    geom_distance = hit_ray_AABB( pos, dir, linac->A_bank_aabb );
    if ( geom_distance < min_distance )
    {
        min_distance = geom_distance;
        in_obj = HIT_BANK_A;
    }

    geom_distance = hit_ray_AABB( pos, dir, linac->B_bank_aabb );
    if ( geom_distance < min_distance )
    {
        min_distance = geom_distance;
        in_obj = HIT_BANK_B;
    }

    // Then check the distance by looking the complete mesh

    if ( in_obj == HIT_JAW_X1 )
    {
        in_obj = HIT_NOTHING;
        min_distance = FLT_MAX;

        itri = 0; while ( itri < linac->X_jaw_nb_triangles[ 0 ] )
        {
            offset = linac->X_jaw_index[ 0 ];
            geom_distance = hit_ray_triangle( pos, dir,
                                              linac->X_jaw_v1[ offset+itri ],
                    linac->X_jaw_v2[ offset+itri ],
                    linac->X_jaw_v3[ offset+itri ] );
            if ( geom_distance < min_distance )
            {
                geom_distance = min_distance;
                in_obj = HIT_JAW_X1;
            }
            ++itri;
        }
    }
    else if ( in_obj == HIT_JAW_X2 )
    {
        in_obj = HIT_NOTHING;
        min_distance = FLT_MAX;

        itri = 0; while ( itri < linac->X_jaw_nb_triangles[ 1 ] )
        {
            offset = linac->X_jaw_index[ 1 ];
            geom_distance = hit_ray_triangle( pos, dir,
                                              linac->X_jaw_v1[ offset+itri ],
                                              linac->X_jaw_v2[ offset+itri ],
                                              linac->X_jaw_v3[ offset+itri ] );
            if ( geom_distance < min_distance )
            {
                geom_distance = min_distance;
                in_obj = HIT_JAW_X2;
            }
            ++itri;
        }
    }
    else if ( in_obj == HIT_JAW_Y1 )
    {
        in_obj = HIT_NOTHING;
        min_distance = FLT_MAX;

        // Loop over triangles
        itri = 0; while ( itri < linac->Y_jaw_nb_triangles[ 0 ] )
        {
            offset = linac->Y_jaw_index[ 0 ];
            geom_distance = hit_ray_triangle( pos, dir,
                                              linac->Y_jaw_v1[ offset+itri ],
                                              linac->Y_jaw_v2[ offset+itri ],
                                              linac->Y_jaw_v3[ offset+itri ] );
            if ( geom_distance < min_distance )
            {
                geom_distance = min_distance;
                in_obj = HIT_JAW_Y1;
            }
            ++itri;
        }
    }
    else if ( in_obj == HIT_JAW_Y2 )
    {
        in_obj = HIT_NOTHING;
        min_distance = FLT_MAX;

        itri = 0; while ( itri < linac->Y_jaw_nb_triangles[ 1 ] )
        {
            offset = linac->Y_jaw_index[ 1 ];
            geom_distance = hit_ray_triangle( pos, dir,
                                              linac->Y_jaw_v1[ offset+itri ],
                                              linac->Y_jaw_v2[ offset+itri ],
                                              linac->Y_jaw_v3[ offset+itri ] );
            if ( geom_distance < min_distance )
            {
                geom_distance = min_distance;
                in_obj = HIT_JAW_Y2;
            }
            ++itri;
        }
    }
    else if ( in_obj == HIT_BANK_A )
    {
        in_obj = HIT_NOTHING;
        min_distance = FLT_MAX;

        ileaf = 0; while( ileaf < linac->A_nb_leaves )
        {
            // If hit a leaf
            if ( test_ray_AABB( pos, dir, linac->A_leaf_aabb[ ileaf ] ) )
            {
                // Loop over triangles
                itri = 0; while ( itri < linac->A_leaf_nb_triangles[ ileaf ] )
                {
                    offset = linac->A_leaf_index[ ileaf ];
                    geom_distance = hit_ray_triangle( pos, dir,
                                                      linac->A_leaf_v1[ offset+itri ],
                                                      linac->A_leaf_v2[ offset+itri ],
                                                      linac->A_leaf_v3[ offset+itri ] );
                    if ( geom_distance < min_distance )
                    {
                        geom_distance = min_distance;
                        in_obj = HIT_BANK_A;
                    }
                    ++itri;
                }
            } // in a leaf bounding box

            ++ileaf;

        } // each leaf
    }
    else if ( in_obj == HIT_BANK_B )
    {
        in_obj = HIT_NOTHING;
        min_distance = FLT_MAX;

        ileaf = 0; while( ileaf < linac->B_nb_leaves )
        {
            // If hit a leaf
            if ( test_ray_AABB( pos, dir, linac->B_leaf_aabb[ ileaf ] ) )
            {
                // Loop over triangles
                itri = 0; while ( itri < linac->B_leaf_nb_triangles[ ileaf ] )
                {
                    offset = linac->B_leaf_index[ ileaf ];
                    geom_distance = hit_ray_triangle( pos, dir,
                                                      linac->B_leaf_v1[ offset+itri ],
                                                      linac->B_leaf_v2[ offset+itri ],
                                                      linac->B_leaf_v3[ offset+itri ] );
                    if ( geom_distance < min_distance )
                    {
                        geom_distance = min_distance;
                        in_obj = HIT_BANK_B;                        
                    }
                    ++itri;
                }
            } // in a leaf bounding box

            ++ileaf;
        }
    }

    if ( in_obj != HIT_NOTHING )
    {
        particles->status[ id ] = PARTICLE_DEAD;
    }
    else
    {
        particles->status[ id ] = PARTICLE_FREEZE;
    }

}


__host__ __device__ void MPLINACN::track_to_out_nonav_nomesh( ParticlesData *particles, const LinacData *linac,
                                                              ui32 id )
{
    // Read position
    f32xyz pos;
    pos.x = particles->px[ id ];
    pos.y = particles->py[ id ];
    pos.z = particles->pz[ id ];

    // Read direction
    f32xyz dir;
    dir.x = particles->dx[ id ];
    dir.y = particles->dy[ id ];
    dir.z = particles->dz[ id ];

    /// Get the hit of the closest geometry //////////////////////////////////

    if ( linac->X_nb_jaw != 0 )
    {
        if ( test_ray_AABB( pos, dir, linac->X_jaw_aabb[ 0 ] ) ||
             test_ray_AABB( pos, dir, linac->X_jaw_aabb[ 1 ] ) )
        {
            particles->status[ id ] = PARTICLE_DEAD;
            return;
        }
    }

    if ( linac->Y_nb_jaw != 0 )
    {
        if ( test_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 0 ] ) ||
             test_ray_AABB( pos, dir, linac->Y_jaw_aabb[ 1 ] ) )
        {
            particles->status[ id ] = PARTICLE_DEAD;
            return;
        }
    }

    if ( test_ray_AABB( pos, dir, linac->A_bank_aabb ) )
    {
        ui16 ileaf = 0; while( ileaf < linac->A_nb_leaves )
        {
            // If hit a leaf
            if ( test_ray_AABB( pos, dir, linac->A_leaf_aabb[ ileaf ] ) )
            {
                particles->status[ id ] = PARTICLE_DEAD;
                return;
            }
            ileaf++;
        }
    }

    if ( test_ray_AABB( pos, dir, linac->B_bank_aabb ) )
    {
        ui16 ileaf = 0; while( ileaf < linac->B_nb_leaves )
        {
            // If hit a leaf
            if ( test_ray_AABB( pos, dir, linac->B_leaf_aabb[ ileaf ] ) )
            {
                particles->status[ id ] = PARTICLE_DEAD;
                return;
            }
            ileaf++;
        }
    }

    particles->status[ id ] = PARTICLE_FREEZE;
}


// Device kernel that track particles within the voxelized volume until boundary
__global__ void MPLINACN::kernel_device_track_to_out( ParticlesData *particles,
                                                      const LinacData *linac,
                                                      const MaterialsData *materials,
                                                      const PhotonCrossSectionData *photon_CS,
                                                      const GlobalSimulationParametersData *parameters,
                                                      ui8 nav_option )
{
    const ui32 id = blockIdx.x * blockDim.x + threadIdx.x;
    if ( id >= particles->size ) return;

    // Init geometry ID for navigation
    particles->geometry_id[ id ] = 0;

    // Stepping loop
    if ( nav_option == NAV_OPT_FULL )
    {       
        while ( particles->status[ id ] != PARTICLE_DEAD && particles->status[ id ] != PARTICLE_FREEZE )
        {
            MPLINACN::track_to_out( particles, linac, materials, photon_CS, parameters, id );
        }
    }
    else if ( nav_option == NAV_OPT_NONAV )
    {
        while ( particles->status[ id ] != PARTICLE_DEAD && particles->status[ id ] != PARTICLE_FREEZE )
        {
            MPLINACN::track_to_out_nonav( particles, linac, id );
        }
    }
    else if ( nav_option == NAV_OPT_NOMESH )
    {
        while ( particles->status[ id ] != PARTICLE_DEAD && particles->status[ id ] != PARTICLE_FREEZE )
        {
            MPLINACN::track_to_out_nomesh( particles, linac, materials, photon_CS, parameters, id );
        }
    }
    else if ( nav_option == NAV_OPT_NOMESH_NONAV )
    {
        while ( particles->status[ id ] != PARTICLE_DEAD && particles->status[ id ] != PARTICLE_FREEZE )
        {
            MPLINACN::track_to_out_nonav_nomesh( particles, linac, id );
        }
    }

    /// Move the particle back to the global frame ///

    // read position and direction
    f32xyz pos = make_f32xyz( particles->px[ id ], particles->py[ id ], particles->pz[ id ] );
    f32xyz dir = make_f32xyz( particles->dx[ id ], particles->dy[ id ], particles->dz[ id ] );

    // Change the frame to the particle (global to linac)
    pos = fxyz_local_to_global_position( linac->transform, pos );
    dir = fxyz_local_to_global_direction( linac->transform, dir );

    // Store data
    particles->px[ id ] = pos.x;
    particles->py[ id ] = pos.y;
    particles->pz[ id ] = pos.z;
    particles->dx[ id ] = dir.x;
    particles->dy[ id ] = dir.y;
    particles->dz[ id ] = dir.z;

}

////// Privates /////////////////////////////////////////////////////////////////////////////

// Read the list of tokens in a txt line
std::vector< std::string > MeshPhanLINACNav::m_split_txt( std::string line ) {

    std::istringstream iss(line);
    std::vector<std::string> tokens;
    std::copy(std::istream_iterator<std::string>(iss),
         std::istream_iterator<std::string>(),
         std::back_inserter(tokens));

    return tokens;

}

void MeshPhanLINACNav::m_init_mlc()
{
    // First check the file
    std::string ext = m_mlc_filename.substr( m_mlc_filename.find_last_of( "." ) + 1 );
    if ( ext != "obj" )
    {
        GGcerr << "MeshPhanLINACNav can only read mesh data in Wavefront format (.obj)!" << GGendl;
        exit_simulation();
    }

    // Then get data
    MeshIO *meshio = new MeshIO;
    MeshData mlc = meshio->read_mesh_file( m_mlc_filename );

    // Check if there are at least one leaf
    if ( mlc.mesh_names.size() == 0 )
    {
        GGcerr << "MeshPhanLINACNav, no leaves in the mlc file were found!" << GGendl;
        exit_simulation();
    }

    // Check if the number of leaves match with the provided parameters
    if ( mh_linac->A_nb_leaves + mh_linac->B_nb_leaves !=  mlc.mesh_names.size() )
    {
        GGcerr << "MeshPhanLINACNav, number of leaves provided by the user is different to the number of meshes contained on the file!" << GGendl;
        exit_simulation();
    }

    // Some allocation
    mh_linac->A_leaf_index = (ui32*)malloc( mh_linac->A_nb_leaves * sizeof( ui32 ) );
    mh_linac->A_leaf_nb_triangles = (ui32*)malloc( mh_linac->A_nb_leaves * sizeof( ui32 ) );
    mh_linac->A_leaf_aabb = (AabbData*)malloc( mh_linac->A_nb_leaves * sizeof( AabbData ) );

    mh_linac->B_leaf_index = (ui32*)malloc( mh_linac->B_nb_leaves * sizeof( ui32 ) );
    mh_linac->B_leaf_nb_triangles = (ui32*)malloc( mh_linac->B_nb_leaves * sizeof( ui32 ) );
    mh_linac->B_leaf_aabb = (AabbData*)malloc( mh_linac->B_nb_leaves * sizeof( AabbData ) );

    // Pre-calculation and checking of the data
    ui32 i_leaf = 0;
    std::string leaf_name, bank_name;
    ui32 index_leaf_bank;
    ui32 tot_tri_bank_A = 0;
    ui32 tot_tri_bank_B = 0;

    while ( i_leaf < mlc.mesh_names.size() )
    {
        // Get name of the leaf
        leaf_name = mlc.mesh_names[ i_leaf ];

        // Bank A or B
        bank_name = leaf_name[ 0 ];

        // Check
        if ( bank_name != "A" && bank_name != "B" )
        {
            GGcerr << "MeshPhanLINACNav: name of each leaf must start by the bank 'A' or 'B', " << bank_name << " given!" << GGendl;
            exit_simulation();
        }

        // Get leaf index
        index_leaf_bank = std::stoi( leaf_name.substr( 1, leaf_name.size()-1 ) );

        // If bank A
        if ( bank_name == "A" )
        {
            // Check
            if ( index_leaf_bank == 0 || index_leaf_bank > mh_linac->A_nb_leaves )
            {
                GGcerr << "MeshPhanLINACNav: name of leaves must have index starting from 1 to N leaves!" << GGendl;
                exit_simulation();
            }

            // Store in sort way te number of triangles for each leaf
            // index_leaf_bank-1 because leaf start from 1 to N
            mh_linac->A_leaf_nb_triangles[ index_leaf_bank-1 ] = mlc.nb_triangles[ i_leaf ];
            tot_tri_bank_A += mlc.nb_triangles[ i_leaf ];

        }

        // If bank B
        if ( bank_name == "B" )
        {
            // Check
            if ( index_leaf_bank == 0 || index_leaf_bank > mh_linac->B_nb_leaves )
            {
                GGcerr << "MeshPhanLINACNav: name of leaves must have index starting from 1 to N leaves!" << GGendl;
                exit_simulation();
            }

            // Store in sort way te number of triangles for each leaf
            // index_leaf_bank-1 because leaf start from 1 to N
            mh_linac->B_leaf_nb_triangles[ index_leaf_bank-1 ] = mlc.nb_triangles[ i_leaf ];
            tot_tri_bank_B += mlc.nb_triangles[ i_leaf ];
       }

        ++i_leaf;
    } // i_leaf

    // Compute the offset for each leaf from bank A
    mh_linac->A_leaf_index[ 0 ] = 0;
    i_leaf = 1; while ( i_leaf < mh_linac->A_nb_leaves )
    {
        mh_linac->A_leaf_index[ i_leaf ] = mh_linac->A_leaf_index[ i_leaf-1 ] + mh_linac->A_leaf_nb_triangles[ i_leaf-1 ];
        ++i_leaf;

    }

    // Compute the offset for each leaf from bank B
    mh_linac->B_leaf_index[ 0 ] = 0;
    i_leaf = 1; while ( i_leaf < mh_linac->B_nb_leaves )
    {
        mh_linac->B_leaf_index[ i_leaf ] = mh_linac->B_leaf_index[ i_leaf-1 ] + mh_linac->B_leaf_nb_triangles[ i_leaf-1 ];
        ++i_leaf;
    }

    // Some others allocations
    mh_linac->A_leaf_v1 = (f32xyz*)malloc( tot_tri_bank_A * sizeof( f32xyz ) );
    mh_linac->A_leaf_v2 = (f32xyz*)malloc( tot_tri_bank_A * sizeof( f32xyz ) );
    mh_linac->A_leaf_v3 = (f32xyz*)malloc( tot_tri_bank_A * sizeof( f32xyz ) );
    mh_linac->A_tot_triangles = tot_tri_bank_A;

    mh_linac->B_leaf_v1 = (f32xyz*)malloc( tot_tri_bank_B * sizeof( f32xyz ) );
    mh_linac->B_leaf_v2 = (f32xyz*)malloc( tot_tri_bank_B * sizeof( f32xyz ) );
    mh_linac->B_leaf_v3 = (f32xyz*)malloc( tot_tri_bank_B * sizeof( f32xyz ) );
    mh_linac->B_tot_triangles = tot_tri_bank_B;

    // Loop over leaf. Organize mesh data into the linac data.
    ui32 i_tri, offset_bank, offset_mlc;
    f32xyz v1, v2, v3;
    f32 xmin, xmax, ymin, ymax, zmin, zmax;
    i_leaf = 0; while ( i_leaf < mlc.mesh_names.size() )
    {
        // Get name of the leaf
        leaf_name = mlc.mesh_names[ i_leaf ];

        // Bank A or B
        bank_name = leaf_name[ 0 ];

        // Get leaf index within the bank
        index_leaf_bank = std::stoi( leaf_name.substr( 1, leaf_name.size()-1 ) ) - 1; // -1 because leaf start from 1 to N

        // index within the mlc (all meshes)
        offset_mlc = mlc.mesh_index[ i_leaf ];

        // Init AABB
        xmin = FLT_MAX; xmax = -FLT_MAX;
        ymin = FLT_MAX; ymax = -FLT_MAX;
        zmin = FLT_MAX; zmax = -FLT_MAX;

        // If bank A
        if ( bank_name == "A" )
        {
            // index within the bank
            offset_bank = mh_linac->A_leaf_index[ index_leaf_bank ];

            // loop over triangles
            i_tri = 0; while ( i_tri < mh_linac->A_leaf_nb_triangles[ index_leaf_bank ] )
            {
                // Store on the right place
                v1 = mlc.v1[ offset_mlc + i_tri ];
                v2 = mlc.v2[ offset_mlc + i_tri ];
                v3 = mlc.v3[ offset_mlc + i_tri ];

                mh_linac->A_leaf_v1[ offset_bank + i_tri ] = v1;
                mh_linac->A_leaf_v2[ offset_bank + i_tri ] = v2;
                mh_linac->A_leaf_v3[ offset_bank + i_tri ] = v3;

                // Determine AABB
                if ( v1.x > xmax ) xmax = v1.x;
                if ( v2.x > xmax ) xmax = v2.x;
                if ( v3.x > xmax ) xmax = v3.x;

                if ( v1.y > ymax ) ymax = v1.y;
                if ( v2.y > ymax ) ymax = v2.y;
                if ( v3.y > ymax ) ymax = v3.y;

                if ( v1.z > zmax ) zmax = v1.z;
                if ( v2.z > zmax ) zmax = v2.z;
                if ( v3.z > zmax ) zmax = v3.z;

                if ( v1.x < xmin ) xmin = v1.x;
                if ( v2.x < xmin ) xmin = v2.x;
                if ( v3.x < xmin ) xmin = v3.x;

                if ( v1.y < ymin ) ymin = v1.y;
                if ( v2.y < ymin ) ymin = v2.y;
                if ( v3.y < ymin ) ymin = v3.y;

                if ( v1.z < zmin ) zmin = v1.z;
                if ( v2.z < zmin ) zmin = v2.z;
                if ( v3.z < zmin ) zmin = v3.z;

                ++i_tri;
            }

            // Store the bounding box of the current leaf
            mh_linac->A_leaf_aabb[ index_leaf_bank ].xmin = xmin;
            mh_linac->A_leaf_aabb[ index_leaf_bank ].xmax = xmax;
            mh_linac->A_leaf_aabb[ index_leaf_bank ].ymin = ymin;
            mh_linac->A_leaf_aabb[ index_leaf_bank ].ymax = ymax;
            mh_linac->A_leaf_aabb[ index_leaf_bank ].zmin = zmin;
            mh_linac->A_leaf_aabb[ index_leaf_bank ].zmax = zmax;


        }
        else // Bank B
        {
            // index within the bank
            offset_bank = mh_linac->B_leaf_index[ index_leaf_bank ];

            // loop over triangles
            i_tri = 0; while ( i_tri < mh_linac->B_leaf_nb_triangles[ index_leaf_bank ] )
            {
                // Store on the right place
                v1 = mlc.v1[ offset_mlc + i_tri ];
                v2 = mlc.v2[ offset_mlc + i_tri ];
                v3 = mlc.v3[ offset_mlc + i_tri ];

                mh_linac->B_leaf_v1[ offset_bank + i_tri ] = v1;
                mh_linac->B_leaf_v2[ offset_bank + i_tri ] = v2;
                mh_linac->B_leaf_v3[ offset_bank + i_tri ] = v3;

                // Determine AABB
                if ( v1.x > xmax ) xmax = v1.x;
                if ( v2.x > xmax ) xmax = v2.x;
                if ( v3.x > xmax ) xmax = v3.x;

                if ( v1.y > ymax ) ymax = v1.y;
                if ( v2.y > ymax ) ymax = v2.y;
                if ( v3.y > ymax ) ymax = v3.y;

                if ( v1.z > zmax ) zmax = v1.z;
                if ( v2.z > zmax ) zmax = v2.z;
                if ( v3.z > zmax ) zmax = v3.z;

                if ( v1.x < xmin ) xmin = v1.x;
                if ( v2.x < xmin ) xmin = v2.x;
                if ( v3.x < xmin ) xmin = v3.x;

                if ( v1.y < ymin ) ymin = v1.y;
                if ( v2.y < ymin ) ymin = v2.y;
                if ( v3.y < ymin ) ymin = v3.y;

                if ( v1.z < zmin ) zmin = v1.z;
                if ( v2.z < zmin ) zmin = v2.z;
                if ( v3.z < zmin ) zmin = v3.z;

                ++i_tri;
            }

            // Store the bounding box of the current leaf
            mh_linac->B_leaf_aabb[ index_leaf_bank ].xmin = xmin;
            mh_linac->B_leaf_aabb[ index_leaf_bank ].xmax = xmax;
            mh_linac->B_leaf_aabb[ index_leaf_bank ].ymin = ymin;
            mh_linac->B_leaf_aabb[ index_leaf_bank ].ymax = ymax;
            mh_linac->B_leaf_aabb[ index_leaf_bank ].zmin = zmin;
            mh_linac->B_leaf_aabb[ index_leaf_bank ].zmax = zmax;

        }

        ++i_leaf;
    } // i_leaf

    // Finally, compute the AABB of the bank A
    xmin = FLT_MAX; xmax = -FLT_MAX;
    ymin = FLT_MAX; ymax = -FLT_MAX;
    zmin = FLT_MAX; zmax = -FLT_MAX;
    i_leaf = 0; while ( i_leaf < mh_linac->A_nb_leaves )
    {
        if ( mh_linac->A_leaf_aabb[ i_leaf ].xmin < xmin ) xmin = mh_linac->A_leaf_aabb[ i_leaf ].xmin;
        if ( mh_linac->A_leaf_aabb[ i_leaf ].ymin < ymin ) ymin = mh_linac->A_leaf_aabb[ i_leaf ].ymin;
        if ( mh_linac->A_leaf_aabb[ i_leaf ].zmin < zmin ) zmin = mh_linac->A_leaf_aabb[ i_leaf ].zmin;

        if ( mh_linac->A_leaf_aabb[ i_leaf ].xmax > xmax ) xmax = mh_linac->A_leaf_aabb[ i_leaf ].xmax;
        if ( mh_linac->A_leaf_aabb[ i_leaf ].ymax > ymax ) ymax = mh_linac->A_leaf_aabb[ i_leaf ].ymax;
        if ( mh_linac->A_leaf_aabb[ i_leaf ].zmax > zmax ) zmax = mh_linac->A_leaf_aabb[ i_leaf ].zmax;

        ++i_leaf;
    }

    mh_linac->A_bank_aabb.xmin = xmin;
    mh_linac->A_bank_aabb.xmax = xmax;
    mh_linac->A_bank_aabb.ymin = ymin;
    mh_linac->A_bank_aabb.ymax = ymax;
    mh_linac->A_bank_aabb.zmin = zmin;
    mh_linac->A_bank_aabb.zmax = zmax;

    // And for the bank B
    xmin = FLT_MAX; xmax = -FLT_MAX;
    ymin = FLT_MAX; ymax = -FLT_MAX;
    zmin = FLT_MAX; zmax = -FLT_MAX;
    i_leaf = 0; while ( i_leaf < mh_linac->B_nb_leaves )
    {
        if ( mh_linac->B_leaf_aabb[ i_leaf ].xmin < xmin ) xmin = mh_linac->B_leaf_aabb[ i_leaf ].xmin;
        if ( mh_linac->B_leaf_aabb[ i_leaf ].ymin < ymin ) ymin = mh_linac->B_leaf_aabb[ i_leaf ].ymin;
        if ( mh_linac->B_leaf_aabb[ i_leaf ].zmin < zmin ) zmin = mh_linac->B_leaf_aabb[ i_leaf ].zmin;

        if ( mh_linac->B_leaf_aabb[ i_leaf ].xmax > xmax ) xmax = mh_linac->B_leaf_aabb[ i_leaf ].xmax;
        if ( mh_linac->B_leaf_aabb[ i_leaf ].ymax > ymax ) ymax = mh_linac->B_leaf_aabb[ i_leaf ].ymax;
        if ( mh_linac->B_leaf_aabb[ i_leaf ].zmax > zmax ) zmax = mh_linac->B_leaf_aabb[ i_leaf ].zmax;

        ++i_leaf;
    }

    mh_linac->B_bank_aabb.xmin = xmin;
    mh_linac->B_bank_aabb.xmax = xmax;
    mh_linac->B_bank_aabb.ymin = ymin;
    mh_linac->B_bank_aabb.ymax = ymax;
    mh_linac->B_bank_aabb.zmin = zmin;
    mh_linac->B_bank_aabb.zmax = zmax;

}


void MeshPhanLINACNav::m_init_jaw_x()
{
    // First check the file
    std::string ext = m_jaw_x_filename.substr( m_jaw_x_filename.find_last_of( "." ) + 1 );
    if ( ext != "obj" )
    {
        GGcerr << "MeshPhanLINACNav can only read mesh data in Wavefront format (.obj)!" << GGendl;
        exit_simulation();
    }

    // Then get data
    MeshIO *meshio = new MeshIO;
    MeshData jaw = meshio->read_mesh_file( m_jaw_x_filename );

    // Check if there are at least one jaw
    if ( jaw.mesh_names.size() == 0 )
    {
        GGcerr << "MeshPhanLINACNav, no jaw in the x-jaw file were found!" << GGendl;
        exit_simulation();
    }

    mh_linac->X_nb_jaw = jaw.mesh_names.size();

    // Some allocation
    mh_linac->X_jaw_index = (ui32*)malloc( mh_linac->X_nb_jaw * sizeof( ui32 ) );
    mh_linac->X_jaw_nb_triangles = (ui32*)malloc( mh_linac->X_nb_jaw * sizeof( ui32 ) );
    mh_linac->X_jaw_aabb = (AabbData*)malloc( mh_linac->X_nb_jaw * sizeof( AabbData ) );

    // Pre-calculation and checking of the data
    ui32 i_jaw = 0;
    std::string jaw_name, axis_name;
    ui32 index_jaw;
    ui32 tot_tri_jaw = 0;

    while ( i_jaw < mh_linac->X_nb_jaw )
    {
        // Get name of the jaw
        jaw_name = jaw.mesh_names[ i_jaw ];

        // Name axis
        axis_name = jaw_name[ 0 ];

        // Check
        if ( axis_name != "X" )
        {
            GGcerr << "MeshPhanLINACNav: name of each jaw (in X) must start by 'X', " << axis_name << " given!" << GGendl;
            exit_simulation();
        }

        // Get leaf index
        index_jaw = std::stoi( jaw_name.substr( 1, jaw_name.size()-1 ) );

        // Check
        if ( index_jaw == 0 || index_jaw > 2 )
        {
            GGcerr << "MeshPhanLINACNav: name of jaws must have index starting from 1 to 2!" << GGendl;
            exit_simulation();
        }

        // Store the number of triangles for each jaw
        // index-1 because jaw start from 1 to 2
        mh_linac->X_jaw_nb_triangles[ index_jaw-1 ] = jaw.nb_triangles[ i_jaw ];
        tot_tri_jaw += jaw.nb_triangles[ i_jaw ];

        ++i_jaw;
    } // i_leaf

    // Compute the offset for each jaw
    mh_linac->X_jaw_index[ 0 ] = 0;
    mh_linac->X_jaw_index[ 1 ] = mh_linac->X_jaw_nb_triangles[ 0 ];

    // Some others allocations
    mh_linac->X_jaw_v1 = (f32xyz*)malloc( tot_tri_jaw * sizeof( f32xyz ) );
    mh_linac->X_jaw_v2 = (f32xyz*)malloc( tot_tri_jaw * sizeof( f32xyz ) );
    mh_linac->X_jaw_v3 = (f32xyz*)malloc( tot_tri_jaw * sizeof( f32xyz ) );
    mh_linac->X_tot_triangles = tot_tri_jaw;

    // Loop over leaf. Organize mesh data into the linac data.
    ui32 i_tri, offset_mesh, offset_linac;
    f32xyz v1, v2, v3;
    f32 xmin, xmax, ymin, ymax, zmin, zmax;
    i_jaw = 0; while ( i_jaw < mh_linac->X_nb_jaw )
    {
        // Get name of the leaf
        jaw_name = jaw.mesh_names[ i_jaw ];

        // Get leaf index within the bank
        index_jaw = std::stoi( jaw_name.substr( 1, jaw_name.size()-1 ) ) - 1; // -1 because jaw start from 1 to 2

        // index within the mlc (all meshes)
        offset_mesh = jaw.mesh_index[ i_jaw ];

        // Init AABB
        xmin = FLT_MAX; xmax = -FLT_MAX;
        ymin = FLT_MAX; ymax = -FLT_MAX;
        zmin = FLT_MAX; zmax = -FLT_MAX;

        // index within the bank
        offset_linac = mh_linac->X_jaw_index[ index_jaw ];

        // loop over triangles
        i_tri = 0; while ( i_tri < mh_linac->X_jaw_nb_triangles[ index_jaw ] )
        {
            // Store on the right place
            v1 = jaw.v1[ offset_mesh + i_tri ];
            v2 = jaw.v2[ offset_mesh + i_tri ];
            v3 = jaw.v3[ offset_mesh + i_tri ];

            mh_linac->X_jaw_v1[ offset_linac + i_tri ] = v1;
            mh_linac->X_jaw_v2[ offset_linac + i_tri ] = v2;
            mh_linac->X_jaw_v3[ offset_linac + i_tri ] = v3;

            // Determine AABB
            if ( v1.x > xmax ) xmax = v1.x;
            if ( v2.x > xmax ) xmax = v2.x;
            if ( v3.x > xmax ) xmax = v3.x;

            if ( v1.y > ymax ) ymax = v1.y;
            if ( v2.y > ymax ) ymax = v2.y;
            if ( v3.y > ymax ) ymax = v3.y;

            if ( v1.z > zmax ) zmax = v1.z;
            if ( v2.z > zmax ) zmax = v2.z;
            if ( v3.z > zmax ) zmax = v3.z;

            if ( v1.x < xmin ) xmin = v1.x;
            if ( v2.x < xmin ) xmin = v2.x;
            if ( v3.x < xmin ) xmin = v3.x;

            if ( v1.y < ymin ) ymin = v1.y;
            if ( v2.y < ymin ) ymin = v2.y;
            if ( v3.y < ymin ) ymin = v3.y;

            if ( v1.z < zmin ) zmin = v1.z;
            if ( v2.z < zmin ) zmin = v2.z;
            if ( v3.z < zmin ) zmin = v3.z;

            ++i_tri;
        }

        // Store the bounding box of the current jaw
        mh_linac->X_jaw_aabb[ index_jaw ].xmin = xmin;
        mh_linac->X_jaw_aabb[ index_jaw ].xmax = xmax;
        mh_linac->X_jaw_aabb[ index_jaw ].ymin = ymin;
        mh_linac->X_jaw_aabb[ index_jaw ].ymax = ymax;
        mh_linac->X_jaw_aabb[ index_jaw ].zmin = zmin;
        mh_linac->X_jaw_aabb[ index_jaw ].zmax = zmax;

        ++i_jaw;
    } // i_jaw

}

void MeshPhanLINACNav::m_init_jaw_y()
{
    // First check the file
    std::string ext = m_jaw_y_filename.substr( m_jaw_y_filename.find_last_of( "." ) + 1 );
    if ( ext != "obj" )
    {
        GGcerr << "MeshPhanLINACNav can only read mesh data in Wavefront format (.obj)!" << GGendl;
        exit_simulation();
    }

    // Then get data
    MeshIO *meshio = new MeshIO;
    MeshData jaw = meshio->read_mesh_file( m_jaw_y_filename );

    // Check if there are at least one jaw
    if ( jaw.mesh_names.size() == 0 )
    {
        GGcerr << "MeshPhanLINACNav, no jaw in the y-jaw file were found!" << GGendl;
        exit_simulation();
    }

    mh_linac->Y_nb_jaw = jaw.mesh_names.size();

    // Some allocation
    mh_linac->Y_jaw_index = (ui32*)malloc( mh_linac->Y_nb_jaw * sizeof( ui32 ) );
    mh_linac->Y_jaw_nb_triangles = (ui32*)malloc( mh_linac->Y_nb_jaw * sizeof( ui32 ) );
    mh_linac->Y_jaw_aabb = (AabbData*)malloc( mh_linac->Y_nb_jaw * sizeof( AabbData ) );

    // Pre-calculation and checking of the data
    ui32 i_jaw = 0;
    std::string jaw_name, axis_name;
    ui32 index_jaw;
    ui32 tot_tri_jaw = 0;

    while ( i_jaw < mh_linac->Y_nb_jaw )
    {
        // Get name of the jaw
        jaw_name = jaw.mesh_names[ i_jaw ];

        // Name axis
        axis_name = jaw_name[ 0 ];

        // Check
        if ( axis_name != "Y" )
        {
            GGcerr << "MeshPhanLINACNav: name of each jaw (in Y) must start by 'Y', " << axis_name << " given!" << GGendl;
            exit_simulation();
        }

        // Get leaf index
        index_jaw = std::stoi( jaw_name.substr( 1, jaw_name.size()-1 ) );

        // Check
        if ( index_jaw == 0 || index_jaw > 2 )
        {
            GGcerr << "MeshPhanLINACNav: name of jaws must have index starting from 1 to 2!" << GGendl;
            exit_simulation();
        }

        // Store the number of triangles for each jaw
        // index-1 because jaw start from 1 to 2
        mh_linac->Y_jaw_nb_triangles[ index_jaw-1 ] = jaw.nb_triangles[ i_jaw ];
        tot_tri_jaw += jaw.nb_triangles[ i_jaw ];

        ++i_jaw;
    } // i_leaf

    // Compute the offset for each jaw
    mh_linac->Y_jaw_index[ 0 ] = 0;
    mh_linac->Y_jaw_index[ 1 ] = mh_linac->Y_jaw_nb_triangles[ 0 ];

    // Some others allocations
    mh_linac->Y_jaw_v1 = (f32xyz*)malloc( tot_tri_jaw * sizeof( f32xyz ) );
    mh_linac->Y_jaw_v2 = (f32xyz*)malloc( tot_tri_jaw * sizeof( f32xyz ) );
    mh_linac->Y_jaw_v3 = (f32xyz*)malloc( tot_tri_jaw * sizeof( f32xyz ) );
    mh_linac->Y_tot_triangles = tot_tri_jaw;

    // Loop over leaf. Organize mesh data into the linac data.
    ui32 i_tri, offset_mesh, offset_linac;
    f32xyz v1, v2, v3;
    f32 xmin, xmax, ymin, ymax, zmin, zmax;
    i_jaw = 0; while ( i_jaw < mh_linac->Y_nb_jaw )
    {
        // Get name of the leaf
        jaw_name = jaw.mesh_names[ i_jaw ];

        // Get leaf index within the bank
        index_jaw = std::stoi( jaw_name.substr( 1, jaw_name.size()-1 ) ) - 1; // -1 because jaw start from 1 to 2

        // index within the mlc (all meshes)
        offset_mesh = jaw.mesh_index[ i_jaw ];

        // Init AABB
        xmin = FLT_MAX; xmax = -FLT_MAX;
        ymin = FLT_MAX; ymax = -FLT_MAX;
        zmin = FLT_MAX; zmax = -FLT_MAX;

        // index within the bank
        offset_linac = mh_linac->Y_jaw_index[ index_jaw ];

        // loop over triangles
        i_tri = 0; while ( i_tri < mh_linac->Y_jaw_nb_triangles[ index_jaw ] )
        {
            // Store on the right place
            v1 = jaw.v1[ offset_mesh + i_tri ];
            v2 = jaw.v2[ offset_mesh + i_tri ];
            v3 = jaw.v3[ offset_mesh + i_tri ];

            mh_linac->Y_jaw_v1[ offset_linac + i_tri ] = v1;
            mh_linac->Y_jaw_v2[ offset_linac + i_tri ] = v2;
            mh_linac->Y_jaw_v3[ offset_linac + i_tri ] = v3;

            // Determine AABB
            if ( v1.x > xmax ) xmax = v1.x;
            if ( v2.x > xmax ) xmax = v2.x;
            if ( v3.x > xmax ) xmax = v3.x;

            if ( v1.y > ymax ) ymax = v1.y;
            if ( v2.y > ymax ) ymax = v2.y;
            if ( v3.y > ymax ) ymax = v3.y;

            if ( v1.z > zmax ) zmax = v1.z;
            if ( v2.z > zmax ) zmax = v2.z;
            if ( v3.z > zmax ) zmax = v3.z;

            if ( v1.x < xmin ) xmin = v1.x;
            if ( v2.x < xmin ) xmin = v2.x;
            if ( v3.x < xmin ) xmin = v3.x;

            if ( v1.y < ymin ) ymin = v1.y;
            if ( v2.y < ymin ) ymin = v2.y;
            if ( v3.y < ymin ) ymin = v3.y;

            if ( v1.z < zmin ) zmin = v1.z;
            if ( v2.z < zmin ) zmin = v2.z;
            if ( v3.z < zmin ) zmin = v3.z;

            ++i_tri;
        }

        // Store the bounding box of the current jaw
        mh_linac->Y_jaw_aabb[ index_jaw ].xmin = xmin;
        mh_linac->Y_jaw_aabb[ index_jaw ].xmax = xmax;
        mh_linac->Y_jaw_aabb[ index_jaw ].ymin = ymin;
        mh_linac->Y_jaw_aabb[ index_jaw ].ymax = ymax;
        mh_linac->Y_jaw_aabb[ index_jaw ].zmin = zmin;
        mh_linac->Y_jaw_aabb[ index_jaw ].zmax = zmax;

        ++i_jaw;
    } // i_jaw

}

void MeshPhanLINACNav::m_translate_jaw_x( ui32 index, f32xyz T )
{
    ui32 offset = mh_linac->X_jaw_index[ index ];
    ui32 nb_tri = mh_linac->X_jaw_nb_triangles[ index ];

    ui32 i_tri = 0; while ( i_tri < nb_tri )
    {
        mh_linac->X_jaw_v1[ offset + i_tri ] = fxyz_add( mh_linac->X_jaw_v1[ offset + i_tri ], T );
        mh_linac->X_jaw_v2[ offset + i_tri ] = fxyz_add( mh_linac->X_jaw_v2[ offset + i_tri ], T );
        mh_linac->X_jaw_v3[ offset + i_tri ] = fxyz_add( mh_linac->X_jaw_v3[ offset + i_tri ], T );
        ++i_tri;
    }

    // Move as well the AABB
    mh_linac->X_jaw_aabb[ index ].xmin += T.x;
    mh_linac->X_jaw_aabb[ index ].xmax += T.x;
    mh_linac->X_jaw_aabb[ index ].ymin += T.y;
    mh_linac->X_jaw_aabb[ index ].ymax += T.y;
    mh_linac->X_jaw_aabb[ index ].zmin += T.z;
    mh_linac->X_jaw_aabb[ index ].zmax += T.z;
}

void MeshPhanLINACNav::m_translate_jaw_y( ui32 index, f32xyz T )
{
    ui32 offset = mh_linac->Y_jaw_index[ index ];
    ui32 nb_tri = mh_linac->Y_jaw_nb_triangles[ index ];

    ui32 i_tri = 0; while ( i_tri < nb_tri )
    {
        mh_linac->Y_jaw_v1[ offset + i_tri ] = fxyz_add( mh_linac->Y_jaw_v1[ offset + i_tri ], T );
        mh_linac->Y_jaw_v2[ offset + i_tri ] = fxyz_add( mh_linac->Y_jaw_v2[ offset + i_tri ], T );
        mh_linac->Y_jaw_v3[ offset + i_tri ] = fxyz_add( mh_linac->Y_jaw_v3[ offset + i_tri ], T );
        ++i_tri;
    }

    // Move as well the AABB
    mh_linac->Y_jaw_aabb[ index ].xmin += T.x;
    mh_linac->Y_jaw_aabb[ index ].xmax += T.x;
    mh_linac->Y_jaw_aabb[ index ].ymin += T.y;
    mh_linac->Y_jaw_aabb[ index ].ymax += T.y;
    mh_linac->Y_jaw_aabb[ index ].zmin += T.z;
    mh_linac->Y_jaw_aabb[ index ].zmax += T.z;
}

void MeshPhanLINACNav::m_translate_leaf_A( ui32 index, f32xyz T )
{
    // If translation is very small, this mean that the leaf is not open
    if (fxyz_mag(T) <= 0.40)  // 0.4 mm
    {
        return;
    }

    ui32 offset = mh_linac->A_leaf_index[ index ];
    ui32 nb_tri = mh_linac->A_leaf_nb_triangles[ index ];

    ui32 i_tri = 0; while ( i_tri < nb_tri )
    {
        mh_linac->A_leaf_v1[ offset + i_tri ] = fxyz_add( mh_linac->A_leaf_v1[ offset + i_tri ], T );
        mh_linac->A_leaf_v2[ offset + i_tri ] = fxyz_add( mh_linac->A_leaf_v2[ offset + i_tri ], T );
        mh_linac->A_leaf_v3[ offset + i_tri ] = fxyz_add( mh_linac->A_leaf_v3[ offset + i_tri ], T );
        ++i_tri;
    }

    // Move as well the AABB
    mh_linac->A_leaf_aabb[ index ].xmin += T.x;
    mh_linac->A_leaf_aabb[ index ].xmax += T.x;
    mh_linac->A_leaf_aabb[ index ].ymin += T.y;
    mh_linac->A_leaf_aabb[ index ].ymax += T.y;
    mh_linac->A_leaf_aabb[ index ].zmin += T.z;
    mh_linac->A_leaf_aabb[ index ].zmax += T.z;

    // Update the bank AABB
    if ( mh_linac->A_leaf_aabb[ index ].xmin < mh_linac->A_bank_aabb.xmin )
    {
        mh_linac->A_bank_aabb.xmin = mh_linac->A_leaf_aabb[ index ].xmin;
    }

    if ( mh_linac->A_leaf_aabb[ index ].ymin < mh_linac->A_bank_aabb.ymin )
    {
        mh_linac->A_bank_aabb.ymin = mh_linac->A_leaf_aabb[ index ].ymin;
    }

    if ( mh_linac->A_leaf_aabb[ index ].zmin < mh_linac->A_bank_aabb.zmin )
    {
        mh_linac->A_bank_aabb.zmin = mh_linac->A_leaf_aabb[ index ].zmin;
    }

    if ( mh_linac->A_leaf_aabb[ index ].xmax > mh_linac->A_bank_aabb.xmax )
    {
        mh_linac->A_bank_aabb.xmax = mh_linac->A_leaf_aabb[ index ].xmax;
    }

    if ( mh_linac->A_leaf_aabb[ index ].ymax > mh_linac->A_bank_aabb.ymax )
    {
        mh_linac->A_bank_aabb.ymax = mh_linac->A_leaf_aabb[ index ].ymax;
    }

    if ( mh_linac->A_leaf_aabb[ index ].zmax > mh_linac->A_bank_aabb.zmax )
    {
        mh_linac->A_bank_aabb.zmax = mh_linac->A_leaf_aabb[ index ].zmax;
    }

}

void MeshPhanLINACNav::m_translate_leaf_B( ui32 index, f32xyz T )
{
    // If translation is very small, this mean that the leaf is not open
    if (fxyz_mag(T) <= 0.40)  // 0.4 mm
    {
        return;
    }

    ui32 offset = mh_linac->B_leaf_index[ index ];
    ui32 nb_tri = mh_linac->B_leaf_nb_triangles[ index ];

    ui32 i_tri = 0; while ( i_tri < nb_tri )
    {
        mh_linac->B_leaf_v1[ offset + i_tri ] = fxyz_add( mh_linac->B_leaf_v1[ offset + i_tri ], T );
        mh_linac->B_leaf_v2[ offset + i_tri ] = fxyz_add( mh_linac->B_leaf_v2[ offset + i_tri ], T );
        mh_linac->B_leaf_v3[ offset + i_tri ] = fxyz_add( mh_linac->B_leaf_v3[ offset + i_tri ], T );
        ++i_tri;
    }

    // Move as well the AABB
    mh_linac->B_leaf_aabb[ index ].xmin += T.x;
    mh_linac->B_leaf_aabb[ index ].xmax += T.x;
    mh_linac->B_leaf_aabb[ index ].ymin += T.y;
    mh_linac->B_leaf_aabb[ index ].ymax += T.y;
    mh_linac->B_leaf_aabb[ index ].zmin += T.z;
    mh_linac->B_leaf_aabb[ index ].zmax += T.z;

    // Update the bank AABB
    if ( mh_linac->B_leaf_aabb[ index ].xmin < mh_linac->B_bank_aabb.xmin )
    {
        mh_linac->B_bank_aabb.xmin = mh_linac->B_leaf_aabb[ index ].xmin;
    }

    if ( mh_linac->B_leaf_aabb[ index ].ymin < mh_linac->B_bank_aabb.ymin )
    {
        mh_linac->B_bank_aabb.ymin = mh_linac->B_leaf_aabb[ index ].ymin;
    }

    if ( mh_linac->B_leaf_aabb[ index ].zmin < mh_linac->B_bank_aabb.zmin )
    {
        mh_linac->B_bank_aabb.zmin = mh_linac->B_leaf_aabb[ index ].zmin;
    }

    if ( mh_linac->B_leaf_aabb[ index ].xmax > mh_linac->B_bank_aabb.xmax )
    {
        mh_linac->B_bank_aabb.xmax = mh_linac->B_leaf_aabb[ index ].xmax;
    }

    if ( mh_linac->B_leaf_aabb[ index ].ymax > mh_linac->B_bank_aabb.ymax )
    {
        mh_linac->B_bank_aabb.ymax = mh_linac->B_leaf_aabb[ index ].ymax;
    }

    if ( mh_linac->B_leaf_aabb[ index ].zmax > mh_linac->B_bank_aabb.zmax )
    {
        mh_linac->B_bank_aabb.zmax = mh_linac->B_leaf_aabb[ index ].zmax;
    }

}

void MeshPhanLINACNav::m_configure_linac()
{

    // Open the beam file
    std::ifstream file( m_beam_config_filename.c_str(), std::ios::in );
    if( !file )
    {
        GGcerr << "Error to open the Beam file'" << m_beam_config_filename << "'!" << GGendl;
        exit_simulation();
    }

    std::string line;
    std::vector< std::string > keys;

    // Look for the beam number
    bool find_beam = false;
    while ( file )
    {
        // Read a line
        std::getline( file, line );
        keys = m_split_txt( line );

        if ( keys.size() >= 3 )
        {
            if ( keys[ 0 ] == "Beam" && std::stoi( keys[ 2 ] ) == m_beam_index )
            {
                find_beam = true;
                break;
            }
        }
    }

    if ( !find_beam )
    {
        GGcerr << "Beam configuration error: beam " << m_beam_index << " was not found!" << GGendl;
        exit_simulation();
    }

    // Then look for the number of fields
    while ( file )
    {
        // Read a line
        std::getline( file, line );

        if ( line.find("Number of Fields") != std::string::npos )
        {
            break;
        }
    }

    keys = m_split_txt( line );
    ui32 nb_fields = std::stoi( keys[ 4 ] );

    if ( m_field_index >= nb_fields )
    {
        GGcerr << "Out of index for the field number, asked: " << m_field_index
               << " but a total of field of " << nb_fields << GGendl;
        exit_simulation();
    }    

    // Look for the number of leaves
    bool find_field = false;
    while ( file )
    {
        // Read a line
        std::getline( file, line );

        if ( line.find("Number of Leaves") != std::string::npos )
        {
            find_field = true;
            break;
        }
    }

    if ( !find_field )
    {
        GGcerr << "Beam configuration error: field " << m_field_index << " was not found!" << GGendl;
        exit_simulation();
    }

    keys = m_split_txt( line );
    ui32 nb_leaves = std::stoi( keys[ 4 ] );
    if ( mh_linac->A_nb_leaves + mh_linac->B_nb_leaves != nb_leaves )
    {
        GGcerr << "Beam configuration error, " << nb_leaves
               << " leaves were found but LINAC model have " << mh_linac->A_nb_leaves + mh_linac->B_nb_leaves
               << " leaves!" << GGendl;
        exit_simulation();
    }

    // Search the required field
    while ( file )
    {
        // Read a line
        std::getline( file, line );
        keys = m_split_txt( line );

        if ( keys.size() >= 3 )
        {
            if ( keys[ 0 ] == "Control" && std::stoi( keys[ 2 ] ) == m_field_index )
            {
                break;
            }
        }
    }

    // Then read the index CDF (not use at the time, so skip the line)
    std::getline( file, line );

    // Get the gantry angle
    std::getline( file, line );

    // Check
    if ( line.find( "Gantry Angle" ) == std::string::npos )
    {
        GGcerr << "Beam configuration error, no gantry angle was found!" << GGendl;
        exit_simulation();
    }

    // Read gantry angle values
    keys = m_split_txt( line );

    // if only one angle, rotate around the z-axis
    if ( keys.size() == 4 )
    {
        m_rot_linac = make_f32xyz( 0.0, 0.0, std::stof( keys[ 3 ] ) *deg );
    }
    else if ( keys.size() == 6 ) // non-coplanar beam, or rotation on the carousel
    {
        m_rot_linac = make_f32xyz( std::stof( keys[ 3 ] ) *deg,
                                   std::stof( keys[ 4 ] ) *deg,
                                   std::stof( keys[ 5 ] ) *deg );
    }
    else // otherwise, it seems that there is an error somewhere
    {
        GGcerr << "Beam configuration error, gantry angle must have one angle or the three rotation angles: "
               << keys.size() - 3 << " angles found!" << GGendl;
        exit_simulation();
    }

    // Get the transformation matrix to map local to global coordinate
    TransformCalculator *trans = new TransformCalculator;
    trans->set_translation( m_pos_mlc );
    trans->set_rotation( m_rot_linac );
    trans->set_axis_transformation( m_axis_linac );
    mh_linac->transform = trans->get_transformation_matrix();
    delete trans;

    //// JAWS //////////////////////////////////////////

    // Next four lines should the jaw config
    f32 jaw_x_min = 0.0; bool jaw_x = false;
    f32 jaw_x_max = 0.0;
    f32 jaw_y_min = 0.0; bool jaw_y = false;
    f32 jaw_y_max = 0.0;

    while ( file )
    {
        // Read a line
        std::getline( file, line );

        if ( line.find( "Jaw" ) != std::string::npos )
        {
            keys = m_split_txt( line );
            if ( keys[ 1 ] == "X" && keys[ 2 ] == "min" )
            {
                jaw_x_min = std::stof( keys[ 4 ] );
                jaw_x = true;
            }
            if ( keys[ 1 ] == "X" && keys[ 2 ] == "max" )
            {
                jaw_x_max = std::stof( keys[ 4 ] );
                jaw_x = true;
            }
            if ( keys[ 1 ] == "Y" && keys[ 2 ] == "min" )
            {
                jaw_y_min = std::stof( keys[ 4 ] );
                jaw_y = true;
            }
            if ( keys[ 1 ] == "Y" && keys[ 2 ] == "max" )
            {
                jaw_y_max = std::stof( keys[ 4 ] );
                jaw_y = true;
            }
        }
        else
        {
            break;
        }
    }

    // Check
    if ( !jaw_x && mh_linac->X_nb_jaw != 0 )
    {
        GGcerr << "Beam configuration error, geometry of the jaw-X was defined but the position values were not found!" << GGendl;
        exit_simulation();
    }
    if ( !jaw_y && mh_linac->Y_nb_jaw != 0 )
    {
        GGcerr << "Beam configuration error, geometry of the jaw-Y was defined but the position values were not found!" << GGendl;
        exit_simulation();
    }

    // Configure the jaws
    if ( mh_linac->X_nb_jaw != 0 )
    {
        m_translate_jaw_x( 0, make_f32xyz( jaw_x_max * mh_linac->xjaw_motion_ratio, 0.0, 0.0 ) );   // X1 ( x > 0 )
        m_translate_jaw_x( 1, make_f32xyz( jaw_x_min * mh_linac->xjaw_motion_ratio, 0.0, 0.0 ) );   // X2 ( x < 0 )
    }

    if ( mh_linac->Y_nb_jaw != 0 )
    {
        m_translate_jaw_y( 0, make_f32xyz( 0.0, jaw_y_max * mh_linac->yjaw_motion_ratio, 0.0 ) );   // Y1 ( y > 0 )
        m_translate_jaw_y( 1, make_f32xyz( 0.0, jaw_y_min * mh_linac->yjaw_motion_ratio, 0.0 ) );   // Y2 ( y < 0 )
    }

    //// LEAVES BANK A ///////////////////////////////////////////////

    ui32 ileaf = 0;
    bool wd_leaf = false; // watchdog
    while ( file )
    {
        if ( line.find( "Leaf" ) != std::string::npos && line.find( "A" ) != std::string::npos )
        {
            // If first leaf of the bank A, check
            if ( ileaf == 0 )
            {
                keys = m_split_txt( line );
                if ( keys[ 1 ] != "1A" )
                {
                    GGcerr << "Beam configuration error, first leaf of the bank A must start by index '1A': " << keys[ 1 ]
                           << " found." << GGendl;
                    exit_simulation();
                }
            }

            // watchdog
            if ( ileaf >= mh_linac->A_nb_leaves )
            {
                GGcerr << "Beam configuration error, find more leaves in the configuration "
                       << "file for the bank A than leaves in the LINAC model!" << GGendl;
                exit_simulation();
            }

            // find at least one leaf
            if ( !wd_leaf ) wd_leaf = true;

            // read data and move the leaf
            keys = m_split_txt( line );
            m_translate_leaf_A( ileaf++, make_f32xyz( std::stof( keys[ 3 ] ) * mh_linac->mlc_motion_ratio, 0.0, 0.0 ) );

        }
        else
        {
            break;
        }

        // Read a line
        std::getline( file, line );
    }

    // No leaves were found
    if ( !wd_leaf )
    {
        GGcerr << "Beam configuration error, no leaves from the bank A were found!" << GGendl;
        exit_simulation();
    }

    //// LEAVES BANK B ///////////////////////////////////////////////

    ileaf = 0;
    wd_leaf = false; // watchdog
    while ( file )
    {

        if ( line.find( "Leaf" ) != std::string::npos && line.find( "B" ) != std::string::npos )
        {
            // If first leaf of the bank A, check
            if ( ileaf == 0 )
            {
                keys = m_split_txt( line );
                if ( keys[ 1 ] != "1B" )
                {
                    GGcerr << "Beam configuration error, first leaf of the bank B must start by index '1B': " << keys[ 1 ]
                           << " found." << GGendl;
                    exit_simulation();
                }
            }

            // watchdog
            if ( ileaf >= mh_linac->B_nb_leaves )
            {
                GGcerr << "Beam configuration error, find more leaves in the configuration "
                       << "file for the bank B than leaves in the LINAC model!" << GGendl;
                exit_simulation();
            }

            // find at least one leaf
            if ( !wd_leaf ) wd_leaf = true;

            // read data and move the leaf
            keys = m_split_txt( line );
            m_translate_leaf_B( ileaf++, make_f32xyz( std::stof( keys[ 3 ] ) * mh_linac->mlc_motion_ratio, 0.0, 0.0 ) );

        }
        else
        {
            break;
        }

        // Read a line
        std::getline( file, line );
    }

    // No leaves were found
    if ( !wd_leaf )
    {
        GGcerr << "Beam configuration error, no leaves from the bank B were found!" << GGendl;
        exit_simulation();
    }

    // Finally compute the global bounding box of the LINAC
    f32 xmin = FLT_MAX; f32 xmax = -FLT_MAX;
    f32 ymin = FLT_MAX; f32 ymax = -FLT_MAX;
    f32 zmin = FLT_MAX; f32 zmax = -FLT_MAX;

    if ( mh_linac->A_bank_aabb.xmin < xmin ) xmin = mh_linac->A_bank_aabb.xmin;
    if ( mh_linac->B_bank_aabb.xmin < xmin ) xmin = mh_linac->B_bank_aabb.xmin;
    if ( mh_linac->A_bank_aabb.ymin < ymin ) ymin = mh_linac->A_bank_aabb.ymin;
    if ( mh_linac->B_bank_aabb.ymin < ymin ) ymin = mh_linac->B_bank_aabb.ymin;
    if ( mh_linac->A_bank_aabb.zmin < zmin ) zmin = mh_linac->A_bank_aabb.zmin;
    if ( mh_linac->B_bank_aabb.zmin < zmin ) zmin = mh_linac->B_bank_aabb.zmin;

    if ( mh_linac->A_bank_aabb.xmax > xmax ) xmax = mh_linac->A_bank_aabb.xmax;
    if ( mh_linac->B_bank_aabb.xmax > xmax ) xmax = mh_linac->B_bank_aabb.xmax;
    if ( mh_linac->A_bank_aabb.ymax > ymax ) ymax = mh_linac->A_bank_aabb.ymax;
    if ( mh_linac->B_bank_aabb.ymax > ymax ) ymax = mh_linac->B_bank_aabb.ymax;
    if ( mh_linac->A_bank_aabb.zmax > zmax ) zmax = mh_linac->A_bank_aabb.zmax;
    if ( mh_linac->B_bank_aabb.zmax > zmax ) zmax = mh_linac->B_bank_aabb.zmax;

    if ( mh_linac->X_nb_jaw != 0 )
    {
        if ( mh_linac->X_jaw_aabb[ 0 ].xmin < xmin ) xmin = mh_linac->X_jaw_aabb[ 0 ].xmin;
        if ( mh_linac->X_jaw_aabb[ 1 ].xmin < xmin ) xmin = mh_linac->X_jaw_aabb[ 1 ].xmin;
        if ( mh_linac->X_jaw_aabb[ 0 ].ymin < ymin ) ymin = mh_linac->X_jaw_aabb[ 0 ].ymin;
        if ( mh_linac->X_jaw_aabb[ 1 ].ymin < ymin ) ymin = mh_linac->X_jaw_aabb[ 1 ].ymin;
        if ( mh_linac->X_jaw_aabb[ 0 ].zmin < zmin ) zmin = mh_linac->X_jaw_aabb[ 0 ].zmin;
        if ( mh_linac->X_jaw_aabb[ 1 ].zmin < zmin ) zmin = mh_linac->X_jaw_aabb[ 1 ].zmin;

        if ( mh_linac->X_jaw_aabb[ 0 ].xmax > xmax ) xmax = mh_linac->X_jaw_aabb[ 0 ].xmax;
        if ( mh_linac->X_jaw_aabb[ 1 ].xmax > xmax ) xmax = mh_linac->X_jaw_aabb[ 1 ].xmax;
        if ( mh_linac->X_jaw_aabb[ 0 ].ymax > ymax ) ymax = mh_linac->X_jaw_aabb[ 0 ].ymax;
        if ( mh_linac->X_jaw_aabb[ 1 ].ymax > ymax ) ymax = mh_linac->X_jaw_aabb[ 1 ].ymax;
        if ( mh_linac->X_jaw_aabb[ 0 ].zmax > zmax ) zmax = mh_linac->X_jaw_aabb[ 0 ].zmax;
        if ( mh_linac->X_jaw_aabb[ 1 ].zmax > zmax ) zmax = mh_linac->X_jaw_aabb[ 1 ].zmax;
    }

    if ( mh_linac->Y_nb_jaw != 0 )
    {
        if ( mh_linac->Y_jaw_aabb[ 0 ].xmin < xmin ) xmin = mh_linac->Y_jaw_aabb[ 0 ].xmin;
        if ( mh_linac->Y_jaw_aabb[ 1 ].xmin < xmin ) xmin = mh_linac->Y_jaw_aabb[ 1 ].xmin;
        if ( mh_linac->Y_jaw_aabb[ 0 ].ymin < ymin ) ymin = mh_linac->Y_jaw_aabb[ 0 ].ymin;
        if ( mh_linac->Y_jaw_aabb[ 1 ].ymin < ymin ) ymin = mh_linac->Y_jaw_aabb[ 1 ].ymin;
        if ( mh_linac->Y_jaw_aabb[ 0 ].zmin < zmin ) zmin = mh_linac->Y_jaw_aabb[ 0 ].zmin;
        if ( mh_linac->Y_jaw_aabb[ 1 ].zmin < zmin ) zmin = mh_linac->Y_jaw_aabb[ 1 ].zmin;

        if ( mh_linac->Y_jaw_aabb[ 0 ].xmax > xmax ) xmax = mh_linac->Y_jaw_aabb[ 0 ].xmax;
        if ( mh_linac->Y_jaw_aabb[ 1 ].xmax > xmax ) xmax = mh_linac->Y_jaw_aabb[ 1 ].xmax;
        if ( mh_linac->Y_jaw_aabb[ 0 ].ymax > ymax ) ymax = mh_linac->Y_jaw_aabb[ 0 ].ymax;
        if ( mh_linac->Y_jaw_aabb[ 1 ].ymax > ymax ) ymax = mh_linac->Y_jaw_aabb[ 1 ].ymax;
        if ( mh_linac->Y_jaw_aabb[ 0 ].zmax > zmax ) zmax = mh_linac->Y_jaw_aabb[ 0 ].zmax;
        if ( mh_linac->Y_jaw_aabb[ 1 ].zmax > zmax ) zmax = mh_linac->Y_jaw_aabb[ 1 ].zmax;
    }

    // Store the data
    mh_linac->aabb.xmin = xmin;
    mh_linac->aabb.xmax = xmax;
    mh_linac->aabb.ymin = ymin;
    mh_linac->aabb.ymax = ymax;
    mh_linac->aabb.zmin = zmin;
    mh_linac->aabb.zmax = zmax;

}



// Free linac data to the CPU
void MeshPhanLINACNav::m_free_linac_to_cpu()
{
    free( mh_linac->A_leaf_v1 );           // Vertex 1  - Triangular meshes
    free( mh_linac->A_leaf_v2 );           // Vertex 2
    free( mh_linac->A_leaf_v3 );           // Vertex 3
    free( mh_linac->A_leaf_index );        // Index to acces to a leaf
    free( mh_linac->A_leaf_nb_triangles ); // Nb of triangles within each leaf
    free( mh_linac->A_leaf_aabb );         // Bounding box of each leaf

    free( mh_linac->B_leaf_v1 );           // Vertex 1  - Triangular meshes
    free( mh_linac->B_leaf_v2 );           // Vertex 2
    free( mh_linac->B_leaf_v3 );           // Vertex 3
    free( mh_linac->B_leaf_index );        // Index to acces to a leaf
    free( mh_linac->B_leaf_nb_triangles ); // Nb of triangles within each leaf
    free( mh_linac->B_leaf_aabb );         // Bounding box of each leaf

    free( mh_linac->X_jaw_v1 );           // Vertex 1  - Triangular meshes
    free( mh_linac->X_jaw_v2 );           // Vertex 2
    free( mh_linac->X_jaw_v3 );           // Vertex 3
    free( mh_linac->X_jaw_index );        // Index to acces to a leaf
    free( mh_linac->X_jaw_nb_triangles ); // Nb of triangles within each leaf
    free( mh_linac->X_jaw_aabb );         // Bounding box of each leaf

    free( mh_linac->Y_jaw_v1 );           // Vertex 1  - Triangular meshes
    free( mh_linac->Y_jaw_v2 );           // Vertex 2
    free( mh_linac->Y_jaw_v3 );           // Vertex 3
    free( mh_linac->Y_jaw_index );        // Index to acces to a leaf
    free( mh_linac->Y_jaw_nb_triangles ); // Nb of triangles within each leaf
    free( mh_linac->Y_jaw_aabb );         // Bounding box of each leaf

    mh_linac->A_leaf_v1 = nullptr;           // Vertex 1  - Triangular meshes
    mh_linac->A_leaf_v2 = nullptr;           // Vertex 2
    mh_linac->A_leaf_v3 = nullptr;           // Vertex 3
    mh_linac->A_leaf_index = nullptr;        // Index to acces to a leaf
    mh_linac->A_leaf_nb_triangles = nullptr; // Nb of triangles within each leaf
    mh_linac->A_leaf_aabb = nullptr;         // Bounding box of each leaf

    // Leaves in Bank B
    mh_linac->B_leaf_v1 = nullptr;           // Vertex 1  - Triangular meshes
    mh_linac->B_leaf_v2 = nullptr;           // Vertex 2
    mh_linac->B_leaf_v3 = nullptr;           // Vertex 3
    mh_linac->B_leaf_index = nullptr;        // Index to acces to a leaf
    mh_linac->B_leaf_nb_triangles = nullptr; // Nb of triangles within each leaf
    mh_linac->B_leaf_aabb = nullptr;         // Bounding box of each leaf

    // Jaws X
    mh_linac->X_jaw_v1 = nullptr;           // Vertex 1  - Triangular meshes
    mh_linac->X_jaw_v2 = nullptr;           // Vertex 2
    mh_linac->X_jaw_v3 = nullptr;           // Vertex 3
    mh_linac->X_jaw_index = nullptr;        // Index to acces to a jaw
    mh_linac->X_jaw_nb_triangles = nullptr; // Nb of triangles within each jaw
    mh_linac->X_jaw_aabb = nullptr;         // Bounding box of each jaw

    // Jaws Y
    mh_linac->Y_jaw_v1 = nullptr;           // Vertex 1  - Triangular meshes
    mh_linac->Y_jaw_v2 = nullptr;           // Vertex 2
    mh_linac->Y_jaw_v3 = nullptr;           // Vertex 3
    mh_linac->Y_jaw_index = nullptr;        // Index to acces to a jaw
    mh_linac->Y_jaw_nb_triangles = nullptr; // Nb of triangles within each jaw
    mh_linac->Y_jaw_aabb = nullptr;         // Bounding box of each jaw

}


// Free linac data to the GPU
void MeshPhanLINACNav::m_free_linac_to_gpu()
{

    /// Device pointers allocation

    f32xyz   *A_leaf_v1;           // Vertex 1  - Triangular meshes
    f32xyz   *A_leaf_v2;           // Vertex 2
    f32xyz   *A_leaf_v3;           // Vertex 3
    ui32     *A_leaf_index;        // Index to acces to a leaf
    ui32     *A_leaf_nb_triangles; // Nb of triangles within each leaf
    AabbData *A_leaf_aabb;         // Bounding box of each leaf

    f32xyz   *B_leaf_v1;           // Vertex 1  - Triangular meshes
    f32xyz   *B_leaf_v2;           // Vertex 2
    f32xyz   *B_leaf_v3;           // Vertex 3
    ui32     *B_leaf_index;        // Index to acces to a leaf
    ui32     *B_leaf_nb_triangles; // Nb of triangles within each leaf
    AabbData *B_leaf_aabb;         // Bounding box of each leaf

    f32xyz   *X_jaw_v1;           // Vertex 1  - Triangular meshes
    f32xyz   *X_jaw_v2;           // Vertex 2
    f32xyz   *X_jaw_v3;           // Vertex 3
    ui32     *X_jaw_index;        // Index to acces to a leaf
    ui32     *X_jaw_nb_triangles; // Nb of triangles within each leaf
    AabbData *X_jaw_aabb;         // Bounding box of each leaf

    f32xyz   *Y_jaw_v1;           // Vertex 1  - Triangular meshes
    f32xyz   *Y_jaw_v2;           // Vertex 2
    f32xyz   *Y_jaw_v3;           // Vertex 3
    ui32     *Y_jaw_index;        // Index to acces to a leaf
    ui32     *Y_jaw_nb_triangles; // Nb of triangles within each leaf
    AabbData *Y_jaw_aabb;         // Bounding box of each leaf

    /// Unbind

    /// Bind data to the struct

    HANDLE_ERROR( cudaMemcpy( &A_leaf_v1, &(md_linac->A_leaf_v1),
                              sizeof(md_linac->A_leaf_v1), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &A_leaf_v2, &(md_linac->A_leaf_v2),
                              sizeof(md_linac->A_leaf_v2), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &A_leaf_v3, &(md_linac->A_leaf_v3),
                              sizeof(md_linac->A_leaf_v3), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &A_leaf_index, &(md_linac->A_leaf_index),
                              sizeof(md_linac->A_leaf_index), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &A_leaf_nb_triangles, &(md_linac->A_leaf_nb_triangles),
                              sizeof(md_linac->A_leaf_nb_triangles), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &A_leaf_aabb, &(md_linac->A_leaf_aabb),
                              sizeof(md_linac->A_leaf_aabb), cudaMemcpyDeviceToHost ) );

    //

    HANDLE_ERROR( cudaMemcpy( &B_leaf_v1, &(md_linac->B_leaf_v1),
                              sizeof(md_linac->B_leaf_v1), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &B_leaf_v2, &(md_linac->B_leaf_v2),
                              sizeof(md_linac->B_leaf_v2), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &B_leaf_v3, &(md_linac->B_leaf_v3),
                              sizeof(md_linac->B_leaf_v3), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &B_leaf_index, &(md_linac->B_leaf_index),
                              sizeof(md_linac->B_leaf_index), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &B_leaf_nb_triangles, &(md_linac->B_leaf_nb_triangles),
                              sizeof(md_linac->B_leaf_nb_triangles), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &B_leaf_aabb, &(md_linac->B_leaf_aabb),
                              sizeof(md_linac->B_leaf_aabb), cudaMemcpyDeviceToHost ) );

    //

    HANDLE_ERROR( cudaMemcpy( &X_jaw_v1, &(md_linac->X_jaw_v1),
                              sizeof(md_linac->X_jaw_v1), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &X_jaw_v2, &(md_linac->X_jaw_v2),
                              sizeof(md_linac->X_jaw_v2), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &X_jaw_v3, &(md_linac->X_jaw_v3),
                              sizeof(md_linac->X_jaw_v3), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &X_jaw_index, &(md_linac->X_jaw_index),
                              sizeof(md_linac->X_jaw_index), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &X_jaw_nb_triangles, &(md_linac->X_jaw_nb_triangles),
                              sizeof(md_linac->X_jaw_nb_triangles), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &X_jaw_aabb, &(md_linac->X_jaw_aabb),
                              sizeof(md_linac->X_jaw_aabb), cudaMemcpyDeviceToHost ) );

    //

    HANDLE_ERROR( cudaMemcpy( &Y_jaw_v1, &(md_linac->Y_jaw_v1),
                              sizeof(md_linac->Y_jaw_v1), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &Y_jaw_v2, &(md_linac->Y_jaw_v2),
                              sizeof(md_linac->Y_jaw_v2), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &Y_jaw_v3, &(md_linac->Y_jaw_v3),
                              sizeof(md_linac->Y_jaw_v3), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &Y_jaw_index, &(md_linac->Y_jaw_index),
                              sizeof(md_linac->Y_jaw_index), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &Y_jaw_nb_triangles, &(md_linac->Y_jaw_nb_triangles),
                              sizeof(md_linac->Y_jaw_nb_triangles), cudaMemcpyDeviceToHost ) );
    HANDLE_ERROR( cudaMemcpy( &Y_jaw_aabb, &(md_linac->Y_jaw_aabb),
                              sizeof(md_linac->Y_jaw_aabb), cudaMemcpyDeviceToHost ) );


    /// Free memory

    cudaFree( A_leaf_v1 );           // Vertex 1  - Triangular meshes
    cudaFree( A_leaf_v2 );           // Vertex 2
    cudaFree( A_leaf_v3 );           // Vertex 3
    cudaFree( A_leaf_index );        // Index to acces to a leaf
    cudaFree( A_leaf_nb_triangles ); // Nb of triangles within each leaf
    cudaFree( A_leaf_aabb );         // Bounding box of each leaf

    cudaFree( B_leaf_v1 );           // Vertex 1  - Triangular meshes
    cudaFree( B_leaf_v2 );           // Vertex 2
    cudaFree( B_leaf_v3 );           // Vertex 3
    cudaFree( B_leaf_index );        // Index to acces to a leaf
    cudaFree( B_leaf_nb_triangles ); // Nb of triangles within each leaf
    cudaFree( B_leaf_aabb );         // Bounding box of each leaf

    cudaFree( X_jaw_v1 );           // Vertex 1  - Triangular meshes
    cudaFree( X_jaw_v2 );           // Vertex 2
    cudaFree( X_jaw_v3 );           // Vertex 3
    cudaFree( X_jaw_index );        // Index to acces to a leaf
    cudaFree( X_jaw_nb_triangles ); // Nb of triangles within each leaf
    cudaFree( X_jaw_aabb );         // Bounding box of each leaf

    cudaFree( Y_jaw_v1 );           // Vertex 1  - Triangular meshes
    cudaFree( Y_jaw_v2 );           // Vertex 2
    cudaFree( Y_jaw_v3 );           // Vertex 3
    cudaFree( Y_jaw_index );        // Index to acces to a leaf
    cudaFree( Y_jaw_nb_triangles ); // Nb of triangles within each leaf
    cudaFree( Y_jaw_aabb );         // Bounding box of each leaf

    cudaFree( md_linac );
}

// Copy linac data to the GPU
void MeshPhanLINACNav::m_copy_linac_to_gpu()
{
    ui32 na_lea = mh_linac->A_nb_leaves;
    ui32 na_tri = mh_linac->A_tot_triangles;
    ui32 nb_lea = mh_linac->B_nb_leaves;
    ui32 nb_tri = mh_linac->B_tot_triangles;

    ui32 nx_lea = mh_linac->X_nb_jaw;
    ui32 nx_tri = mh_linac->X_tot_triangles;
    ui32 ny_lea = mh_linac->Y_nb_jaw;
    ui32 ny_tri = mh_linac->Y_tot_triangles;

    /// First, struct allocation

    HANDLE_ERROR( cudaMalloc( (void**) &md_linac, sizeof( LinacData ) ) );

    /// Device pointers allocation

    f32xyz   *A_leaf_v1;           // Vertex 1  - Triangular meshes
    HANDLE_ERROR( cudaMalloc((void**) &A_leaf_v1, na_tri*sizeof(f32xyz)) );
    f32xyz   *A_leaf_v2;           // Vertex 2
    HANDLE_ERROR( cudaMalloc((void**) &A_leaf_v2, na_tri*sizeof(f32xyz)) );
    f32xyz   *A_leaf_v3;           // Vertex 3
    HANDLE_ERROR( cudaMalloc((void**) &A_leaf_v3, na_tri*sizeof(f32xyz)) );
    ui32     *A_leaf_index;        // Index to acces to a leaf
    HANDLE_ERROR( cudaMalloc((void**) &A_leaf_index, na_lea*sizeof(ui32)) );
    ui32     *A_leaf_nb_triangles; // Nb of triangles within each leaf
    HANDLE_ERROR( cudaMalloc((void**) &A_leaf_nb_triangles, na_lea*sizeof(ui32)) );
    AabbData *A_leaf_aabb;         // Bounding box of each leaf
    HANDLE_ERROR( cudaMalloc((void**) &A_leaf_aabb, na_lea*sizeof(AabbData)) );

    f32xyz   *B_leaf_v1;           // Vertex 1  - Triangular meshes
    HANDLE_ERROR( cudaMalloc((void**) &B_leaf_v1, nb_tri*sizeof(f32xyz)) );
    f32xyz   *B_leaf_v2;           // Vertex 2
    HANDLE_ERROR( cudaMalloc((void**) &B_leaf_v2, nb_tri*sizeof(f32xyz)) );
    f32xyz   *B_leaf_v3;           // Vertex 3
    HANDLE_ERROR( cudaMalloc((void**) &B_leaf_v3, nb_tri*sizeof(f32xyz)) );
    ui32     *B_leaf_index;        // Index to acces to a leaf
    HANDLE_ERROR( cudaMalloc((void**) &B_leaf_index, nb_lea*sizeof(ui32)) );
    ui32     *B_leaf_nb_triangles; // Nb of triangles within each leaf
    HANDLE_ERROR( cudaMalloc((void**) &B_leaf_nb_triangles, nb_lea*sizeof(ui32)) );
    AabbData *B_leaf_aabb;         // Bounding box of each leaf
    HANDLE_ERROR( cudaMalloc((void**) &B_leaf_aabb, nb_lea*sizeof(AabbData)) );

    f32xyz   *X_jaw_v1;           // Vertex 1  - Triangular meshes
    HANDLE_ERROR( cudaMalloc((void**) &X_jaw_v1, nx_tri*sizeof(f32xyz)) );
    f32xyz   *X_jaw_v2;           // Vertex 2
    HANDLE_ERROR( cudaMalloc((void**) &X_jaw_v2, nx_tri*sizeof(f32xyz)) );
    f32xyz   *X_jaw_v3;           // Vertex 3
    HANDLE_ERROR( cudaMalloc((void**) &X_jaw_v3, nx_tri*sizeof(f32xyz)) );
    ui32     *X_jaw_index;        // Index to acces to a leaf
    HANDLE_ERROR( cudaMalloc((void**) &X_jaw_index, nx_lea*sizeof(ui32)) );
    ui32     *X_jaw_nb_triangles; // Nb of triangles within each leaf
    HANDLE_ERROR( cudaMalloc((void**) &X_jaw_nb_triangles, nx_lea*sizeof(ui32)) );
    AabbData *X_jaw_aabb;         // Bounding box of each leaf
    HANDLE_ERROR( cudaMalloc((void**) &X_jaw_aabb, nx_lea*sizeof(AabbData)) );

    f32xyz   *Y_jaw_v1;           // Vertex 1  - Triangular meshes
    HANDLE_ERROR( cudaMalloc((void**) &Y_jaw_v1, ny_tri*sizeof(f32xyz)) );
    f32xyz   *Y_jaw_v2;           // Vertex 2
    HANDLE_ERROR( cudaMalloc((void**) &Y_jaw_v2, ny_tri*sizeof(f32xyz)) );
    f32xyz   *Y_jaw_v3;           // Vertex 3
    HANDLE_ERROR( cudaMalloc((void**) &Y_jaw_v3, ny_tri*sizeof(f32xyz)) );
    ui32     *Y_jaw_index;        // Index to acces to a leaf
    HANDLE_ERROR( cudaMalloc((void**) &Y_jaw_index, ny_lea*sizeof(ui32)) );
    ui32     *Y_jaw_nb_triangles; // Nb of triangles within each leaf
    HANDLE_ERROR( cudaMalloc((void**) &Y_jaw_nb_triangles, ny_lea*sizeof(ui32)) );
    AabbData *Y_jaw_aabb;         // Bounding box of each leaf
    HANDLE_ERROR( cudaMalloc((void**) &Y_jaw_aabb, ny_lea*sizeof(AabbData)) );

    /// Copy host data to device

    HANDLE_ERROR( cudaMemcpy( A_leaf_v1, mh_linac->A_leaf_v1,
                              na_tri*sizeof(f32xyz), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( A_leaf_v2, mh_linac->A_leaf_v2,
                              na_tri*sizeof(f32xyz), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( A_leaf_v3, mh_linac->A_leaf_v3,
                              na_tri*sizeof(f32xyz), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( A_leaf_index, mh_linac->A_leaf_index,
                              na_lea*sizeof(ui32), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( A_leaf_nb_triangles, mh_linac->A_leaf_nb_triangles,
                              na_lea*sizeof(ui32), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( A_leaf_aabb, mh_linac->A_leaf_aabb,
                              na_lea*sizeof(AabbData), cudaMemcpyHostToDevice ) );

    HANDLE_ERROR( cudaMemcpy( B_leaf_v1, mh_linac->B_leaf_v1,
                              nb_tri*sizeof(f32xyz), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( B_leaf_v2, mh_linac->B_leaf_v2,
                              nb_tri*sizeof(f32xyz), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( B_leaf_v3, mh_linac->B_leaf_v3,
                              nb_tri*sizeof(f32xyz), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( B_leaf_index, mh_linac->B_leaf_index,
                              nb_lea*sizeof(ui32), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( B_leaf_nb_triangles, mh_linac->B_leaf_nb_triangles,
                              nb_lea*sizeof(ui32), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( B_leaf_aabb, mh_linac->B_leaf_aabb,
                              nb_lea*sizeof(AabbData), cudaMemcpyHostToDevice ) );

    HANDLE_ERROR( cudaMemcpy( X_jaw_v1, mh_linac->X_jaw_v1,
                              nx_tri*sizeof(f32xyz), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( X_jaw_v2, mh_linac->X_jaw_v2,
                              nx_tri*sizeof(f32xyz), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( X_jaw_v3, mh_linac->X_jaw_v3,
                              nx_tri*sizeof(f32xyz), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( X_jaw_index, mh_linac->X_jaw_index,
                              nx_lea*sizeof(ui32), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( X_jaw_nb_triangles, mh_linac->X_jaw_nb_triangles,
                              nx_lea*sizeof(ui32), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( X_jaw_aabb, mh_linac->X_jaw_aabb,
                              nx_lea*sizeof(AabbData), cudaMemcpyHostToDevice ) );

    HANDLE_ERROR( cudaMemcpy( Y_jaw_v1, mh_linac->Y_jaw_v1,
                              ny_tri*sizeof(f32xyz), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( Y_jaw_v2, mh_linac->Y_jaw_v2,
                              ny_tri*sizeof(f32xyz), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( Y_jaw_v3, mh_linac->Y_jaw_v3,
                              ny_tri*sizeof(f32xyz), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( Y_jaw_index, mh_linac->Y_jaw_index,
                              ny_lea*sizeof(ui32), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( Y_jaw_nb_triangles, mh_linac->Y_jaw_nb_triangles,
                              ny_lea*sizeof(ui32), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( Y_jaw_aabb, mh_linac->Y_jaw_aabb,
                              ny_lea*sizeof(AabbData), cudaMemcpyHostToDevice ) );

    /// Bind data to the struct

    HANDLE_ERROR( cudaMemcpy( &(md_linac->A_leaf_v1), &A_leaf_v1,
                              sizeof(md_linac->A_leaf_v1), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->A_leaf_v2), &A_leaf_v2,
                              sizeof(md_linac->A_leaf_v2), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->A_leaf_v3), &A_leaf_v3,
                              sizeof(md_linac->A_leaf_v3), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->A_leaf_index), &A_leaf_index,
                              sizeof(md_linac->A_leaf_index), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->A_leaf_nb_triangles), &A_leaf_nb_triangles,
                              sizeof(md_linac->A_leaf_nb_triangles), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->A_leaf_aabb), &A_leaf_aabb,
                              sizeof(md_linac->A_leaf_aabb), cudaMemcpyHostToDevice ) );

    HANDLE_ERROR( cudaMemcpy( &(md_linac->A_bank_aabb), &(mh_linac->A_bank_aabb),
                              sizeof(md_linac->A_bank_aabb), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->A_nb_leaves), &(mh_linac->A_nb_leaves),
                              sizeof(md_linac->A_nb_leaves), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->A_tot_triangles), &(mh_linac->A_tot_triangles),
                              sizeof(md_linac->A_tot_triangles), cudaMemcpyHostToDevice ) );

    //

    HANDLE_ERROR( cudaMemcpy( &(md_linac->B_leaf_v1), &B_leaf_v1,
                              sizeof(md_linac->B_leaf_v1), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->B_leaf_v2), &B_leaf_v2,
                              sizeof(md_linac->B_leaf_v2), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->B_leaf_v3), &B_leaf_v3,
                              sizeof(md_linac->B_leaf_v3), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->B_leaf_index), &B_leaf_index,
                              sizeof(md_linac->B_leaf_index), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->B_leaf_nb_triangles), &B_leaf_nb_triangles,
                              sizeof(md_linac->B_leaf_nb_triangles), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->B_leaf_aabb), &B_leaf_aabb,
                              sizeof(md_linac->B_leaf_aabb), cudaMemcpyHostToDevice ) );

    HANDLE_ERROR( cudaMemcpy( &(md_linac->B_bank_aabb), &(mh_linac->B_bank_aabb),
                              sizeof(md_linac->B_bank_aabb), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->B_nb_leaves), &(mh_linac->B_nb_leaves),
                              sizeof(md_linac->B_nb_leaves), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->B_tot_triangles), &(mh_linac->B_tot_triangles),
                              sizeof(md_linac->B_tot_triangles), cudaMemcpyHostToDevice ) );

    //

    HANDLE_ERROR( cudaMemcpy( &(md_linac->X_jaw_v1), &X_jaw_v1,
                              sizeof(md_linac->X_jaw_v1), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->X_jaw_v2), &X_jaw_v2,
                              sizeof(md_linac->X_jaw_v2), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->X_jaw_v3), &X_jaw_v3,
                              sizeof(md_linac->X_jaw_v3), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->X_jaw_index), &X_jaw_index,
                              sizeof(md_linac->X_jaw_index), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->X_jaw_nb_triangles), &X_jaw_nb_triangles,
                              sizeof(md_linac->X_jaw_nb_triangles), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->X_jaw_aabb), &X_jaw_aabb,
                              sizeof(md_linac->X_jaw_aabb), cudaMemcpyHostToDevice ) );

    HANDLE_ERROR( cudaMemcpy( &(md_linac->X_nb_jaw), &(mh_linac->X_nb_jaw),
                              sizeof(md_linac->X_nb_jaw), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->X_tot_triangles), &(mh_linac->X_tot_triangles),
                              sizeof(md_linac->X_tot_triangles), cudaMemcpyHostToDevice ) );

    //

    HANDLE_ERROR( cudaMemcpy( &(md_linac->Y_jaw_v1), &Y_jaw_v1,
                              sizeof(md_linac->Y_jaw_v1), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->Y_jaw_v2), &Y_jaw_v2,
                              sizeof(md_linac->Y_jaw_v2), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->Y_jaw_v3), &Y_jaw_v3,
                              sizeof(md_linac->Y_jaw_v3), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->Y_jaw_index), &Y_jaw_index,
                              sizeof(md_linac->Y_jaw_index), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->Y_jaw_nb_triangles), &Y_jaw_nb_triangles,
                              sizeof(md_linac->Y_jaw_nb_triangles), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->Y_jaw_aabb), &Y_jaw_aabb,
                              sizeof(md_linac->Y_jaw_aabb), cudaMemcpyHostToDevice ) );

    HANDLE_ERROR( cudaMemcpy( &(md_linac->Y_nb_jaw), &(mh_linac->Y_nb_jaw),
                              sizeof(md_linac->Y_nb_jaw), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->Y_tot_triangles), &(mh_linac->Y_tot_triangles),
                              sizeof(md_linac->Y_tot_triangles), cudaMemcpyHostToDevice ) );

    //

    HANDLE_ERROR( cudaMemcpy( &(md_linac->aabb), &(mh_linac->aabb),
                              sizeof(md_linac->aabb), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->transform), &(mh_linac->transform),
                              sizeof(md_linac->transform), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->mlc_motion_ratio), &(mh_linac->mlc_motion_ratio),
                              sizeof(md_linac->mlc_motion_ratio), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->xjaw_motion_ratio), &(mh_linac->xjaw_motion_ratio),
                              sizeof(md_linac->xjaw_motion_ratio), cudaMemcpyHostToDevice ) );
    HANDLE_ERROR( cudaMemcpy( &(md_linac->yjaw_motion_ratio), &(mh_linac->yjaw_motion_ratio),
                              sizeof(md_linac->yjaw_motion_ratio), cudaMemcpyHostToDevice ) );

}

// return memory usage
ui64 MeshPhanLINACNav::m_get_memory_usage()
{
    ui64 mem = 0;

    // Get tot nb triangles
    ui32 tot_tri = 0;

    ui32 ileaf = 0; while ( ileaf < mh_linac->A_nb_leaves )
    {
        tot_tri += mh_linac->A_leaf_nb_triangles[ ileaf++ ];
    }

    ileaf = 0; while ( ileaf < mh_linac->B_nb_leaves )
    {
        tot_tri += mh_linac->B_leaf_nb_triangles[ ileaf++ ];
    }

    if ( mh_linac->X_nb_jaw != 0 )
    {
        tot_tri += mh_linac->X_jaw_nb_triangles[ 0 ];
        tot_tri += mh_linac->X_jaw_nb_triangles[ 1 ];
    }

    if ( mh_linac->Y_nb_jaw != 0 )
    {
        tot_tri += mh_linac->Y_jaw_nb_triangles[ 0 ];
        tot_tri += mh_linac->Y_jaw_nb_triangles[ 1 ];
    }

    // All tri
    mem = 3 * tot_tri * sizeof( f32xyz );

    // Bank A
    mem += mh_linac->A_nb_leaves * 2 * sizeof( ui32 ); // index, nb tri
    mem += mh_linac->A_nb_leaves * 6 * sizeof( f32 );  // aabb
    mem += 6 * sizeof( f32 ) + sizeof( ui32 );       // main aabb, nb leaves

    // Bank B
    mem += mh_linac->B_nb_leaves * 2 * sizeof( ui32 ); // index, nb tri
    mem += mh_linac->B_nb_leaves * 6 * sizeof( f32 );  // aabb
    mem += 6 * sizeof( f32 ) + sizeof( ui32 );       // main aabb, nb leaves

    // Jaws X
    mem += mh_linac->X_nb_jaw * 2 * sizeof( ui32 );    // inedx, nb tri
    mem += 6 * sizeof( f32 ) + sizeof( ui32 );       // main aabb, nb jaws

    // Jaws Y
    mem += mh_linac->Y_nb_jaw * 2 * sizeof( ui32 );    // inedx, nb tri
    mem += 6 * sizeof( f32 ) + sizeof( ui32 );       // main aabb, nb jaws

    // Global aabb
    mem += 6 * sizeof( f32 );

    return mem;
}

//// Setting/Getting functions

void MeshPhanLINACNav::set_mlc_meshes( std::string filename )
{
    m_mlc_filename = filename;
}

void MeshPhanLINACNav::set_jaw_x_meshes( std::string filename )
{
    m_jaw_x_filename = filename;
}

void MeshPhanLINACNav::set_jaw_y_meshes( std::string filename )
{
    m_jaw_y_filename = filename;
}

void MeshPhanLINACNav::set_beam_configuration( std::string filename, ui32 beam_index, ui32 field_index )
{
    m_beam_config_filename = filename;
    m_beam_index = beam_index;
    m_field_index = field_index;
}

void MeshPhanLINACNav::set_number_of_leaves( ui32 nb_bank_A, ui32 nb_bank_B )
{
    mh_linac->A_nb_leaves = nb_bank_A;
    mh_linac->B_nb_leaves = nb_bank_B;
}

void MeshPhanLINACNav::set_mlc_position( f32 px, f32 py, f32 pz )
{
    m_pos_mlc = make_f32xyz( px, py, pz );
}

void MeshPhanLINACNav::set_local_jaw_x_position( f32 px, f32 py, f32 pz )
{
    m_loc_pos_jaw_x = make_f32xyz( px, py, pz );
}

void MeshPhanLINACNav::set_local_jaw_y_position( f32 px, f32 py, f32 pz )
{
    m_loc_pos_jaw_y = make_f32xyz( px, py, pz );
}

void MeshPhanLINACNav::set_mlc_motion_scaling_factor( f32 scale )
{
    mh_linac->mlc_motion_ratio = scale;
}

void MeshPhanLINACNav::set_jaw_x_motion_scaling_factor( f32 scale )
{
    mh_linac->xjaw_motion_ratio = scale;
}

void MeshPhanLINACNav::set_jaw_y_motion_scaling_factor( f32 scale )
{
    mh_linac->yjaw_motion_ratio = scale;
}

void MeshPhanLINACNav::set_linac_local_axis( f32 m00, f32 m01, f32 m02,
                                             f32 m10, f32 m11, f32 m12,
                                             f32 m20, f32 m21, f32 m22 )
{
    m_axis_linac = make_f32matrix33( m00, m01, m02,
                                     m10, m11, m12,
                                     m20, m21, m22 );
}

void MeshPhanLINACNav::set_navigation_option( std::string opt )
{
    // Transform the name of the process in small letter
    std::transform( opt.begin(), opt.end(), opt.begin(), ::tolower );

    if ( opt == "full" || opt == "navmesh" || opt == "meshnav" )
    {
        m_nav_option = NAV_OPT_FULL;
    }
    else if ( opt == "nonav" )
    {
        m_nav_option = NAV_OPT_NONAV;
    }
    else if ( opt == "nomesh" )
    {
        m_nav_option = NAV_OPT_NOMESH;

    }
    else if ( opt == "nomeshnonav" || opt == "nonavnomesh")
    {
        m_nav_option = NAV_OPT_NOMESH_NONAV;
    }
    else
    {
        GGcerr << "Navigation option for MeshPhanLINACNav is not recognized!" << GGendl;
        exit_simulation();
    }
}

void MeshPhanLINACNav::set_linac_material( std::string mat_name )
{
    m_linac_material[ 0 ] = mat_name;
}

void MeshPhanLINACNav::set_source_to_isodose_distance( f32 dist )
{
    m_sid = dist;
}

LinacData* MeshPhanLINACNav::get_linac_geometry()
{
    return mh_linac;
}

f32matrix44 MeshPhanLINACNav::get_linac_transformation()
{
    return mh_linac->transform;
}

void MeshPhanLINACNav::set_materials(std::string filename )
{
    m_materials_filename = filename;
}

void MeshPhanLINACNav::update_beam_configuration( std::string filename, ui32 beam_index, ui32 field_index )
{
    m_beam_config_filename = filename;
    m_beam_index = beam_index;
    m_field_index = field_index;

    // Init linac configuration
    m_free_linac_to_cpu();

    /// Init Jaws

    // If jaw x is defined, init
    if ( m_jaw_x_filename != "" )
    {
        m_init_jaw_x();

        // place the jaw relatively to the mlc (local frame)
        m_translate_jaw_x( 0, m_loc_pos_jaw_x );
        m_translate_jaw_x( 1, m_loc_pos_jaw_x );
    }

    // If jaw y is defined, init
    if ( m_jaw_y_filename != "" )
    {
        m_init_jaw_y();

        // place the jaw relatively to the mlc (local frame)
        m_translate_jaw_y( 0, m_loc_pos_jaw_y );
        m_translate_jaw_y( 1, m_loc_pos_jaw_y );
    }

    // Init MLC
    m_init_mlc();

    // Configure the linac
    m_configure_linac();

    // Free linac to the GPU
    m_free_linac_to_gpu();

    // Copy the linac to the GPU
    m_copy_linac_to_gpu();

}


////// Main functions

MeshPhanLINACNav::MeshPhanLINACNav ()
{
    // Allocate and init struct
    mh_linac = (LinacData*)malloc( sizeof( LinacData ) );
    md_linac = nullptr;

    // Leaves in Bank A
    mh_linac->A_leaf_v1 = nullptr;           // Vertex 1  - Triangular meshes
    mh_linac->A_leaf_v2 = nullptr;           // Vertex 2
    mh_linac->A_leaf_v3 = nullptr;           // Vertex 3
    mh_linac->A_leaf_index = nullptr;        // Index to acces to a leaf
    mh_linac->A_leaf_nb_triangles = nullptr; // Nb of triangles within each leaf
    mh_linac->A_leaf_aabb = nullptr;         // Bounding box of each leaf

    mh_linac->A_bank_aabb.xmin = 0.0;     // Bounding box of the bank A
    mh_linac->A_bank_aabb.xmax = 0.0;
    mh_linac->A_bank_aabb.ymin = 0.0;
    mh_linac->A_bank_aabb.ymax = 0.0;
    mh_linac->A_bank_aabb.zmin = 0.0;
    mh_linac->A_bank_aabb.zmax = 0.0;

    mh_linac->A_nb_leaves = 0;            // Number of leaves in the bank A
    mh_linac->A_tot_triangles = 0;

    // Leaves in Bank B
    mh_linac->B_leaf_v1 = nullptr;           // Vertex 1  - Triangular meshes
    mh_linac->B_leaf_v2 = nullptr;           // Vertex 2
    mh_linac->B_leaf_v3 = nullptr;           // Vertex 3
    mh_linac->B_leaf_index = nullptr;        // Index to acces to a leaf
    mh_linac->B_leaf_nb_triangles = nullptr; // Nb of triangles within each leaf
    mh_linac->B_leaf_aabb = nullptr;         // Bounding box of each leaf

    mh_linac->B_bank_aabb.xmin = 0.0;     // Bounding box of the bank B
    mh_linac->B_bank_aabb.xmax = 0.0;
    mh_linac->B_bank_aabb.ymin = 0.0;
    mh_linac->B_bank_aabb.ymax = 0.0;
    mh_linac->B_bank_aabb.zmin = 0.0;
    mh_linac->B_bank_aabb.zmax = 0.0;

    mh_linac->B_nb_leaves = 0;            // Number of leaves in the bank B
    mh_linac->B_tot_triangles = 0;

    // Jaws X
    mh_linac->X_jaw_v1 = nullptr;           // Vertex 1  - Triangular meshes
    mh_linac->X_jaw_v2 = nullptr;           // Vertex 2
    mh_linac->X_jaw_v3 = nullptr;           // Vertex 3
    mh_linac->X_jaw_index = nullptr;        // Index to acces to a jaw
    mh_linac->X_jaw_nb_triangles = nullptr; // Nb of triangles within each jaw
    mh_linac->X_jaw_aabb = nullptr;         // Bounding box of each jaw
    mh_linac->X_nb_jaw = 0;              // Number of jaws
    mh_linac->X_tot_triangles = 0;

    // Jaws Y
    mh_linac->Y_jaw_v1 = nullptr;           // Vertex 1  - Triangular meshes
    mh_linac->Y_jaw_v2 = nullptr;           // Vertex 2
    mh_linac->Y_jaw_v3 = nullptr;           // Vertex 3
    mh_linac->Y_jaw_index = nullptr;        // Index to acces to a jaw
    mh_linac->Y_jaw_nb_triangles = nullptr; // Nb of triangles within each jaw
    mh_linac->Y_jaw_aabb = nullptr;         // Bounding box of each jaw
    mh_linac->Y_nb_jaw = 0;              // Number of jaws
    mh_linac->Y_tot_triangles = 0;

    mh_linac->aabb.xmin = 0.0;           // Bounding box of the LINAC
    mh_linac->aabb.xmax = 0.0;
    mh_linac->aabb.ymin = 0.0;
    mh_linac->aabb.ymax = 0.0;
    mh_linac->aabb.zmin = 0.0;
    mh_linac->aabb.zmax = 0.0;

    mh_linac->transform = make_f32matrix44_zeros();

    mh_linac->mlc_motion_ratio = -1.0;
    mh_linac->xjaw_motion_ratio = -1.0;
    mh_linac->yjaw_motion_ratio = -1.0;

    set_name( "MeshPhanLINACNav" );
    m_mlc_filename = "";
    m_jaw_x_filename = "";
    m_jaw_y_filename = "";
    m_beam_config_filename = "";

    m_pos_mlc = make_f32xyz_zeros();
    m_loc_pos_jaw_x = make_f32xyz_zeros();
    m_loc_pos_jaw_y = make_f32xyz_zeros();
    m_rot_linac = make_f32xyz_zeros();
    m_axis_linac = make_f32matrix33_zeros();
    m_sid = 0.0f;

    m_beam_index = 0;
    m_field_index = 0;

    m_nav_option = NAV_OPT_FULL;
    m_materials_filename = "";
    m_linac_material.push_back("");

    mh_params = nullptr;
    md_params = nullptr;

}

//// Mandatory functions

void MeshPhanLINACNav::track_to_in( ParticlesData *d_particles )
{

    dim3 threads, grid;
    threads.x = mh_params->gpu_block_size;
    grid.x = ( mh_params->size_of_particles_batch + mh_params->gpu_block_size - 1 ) / mh_params->gpu_block_size;

    MPLINACN::kernel_device_track_to_in<<<grid, threads>>>( d_particles, md_linac,
                                                            mh_params->geom_tolerance );
    cuda_error_check ( "Error ", " Kernel_MeshPhanLINACNav (track to in)" );
    cudaDeviceSynchronize();

}

void MeshPhanLINACNav::track_to_out(ParticlesData *d_particles )
{

    dim3 threads, grid;
    threads.x = mh_params->gpu_block_size;
    grid.x = ( mh_params->size_of_particles_batch + mh_params->gpu_block_size - 1 ) / mh_params->gpu_block_size;

    MPLINACN::kernel_device_track_to_out<<<grid, threads>>>( d_particles, md_linac,
                                                             m_materials.d_materials, m_cross_sections.d_photon_CS,
                                                             md_params, m_nav_option );
    cuda_error_check ( "Error ", " Kernel_MeshPhanLINACNav (track to in)" );
    cudaDeviceSynchronize();    

}

void MeshPhanLINACNav::initialize(GlobalSimulationParametersData *h_params , GlobalSimulationParametersData *d_params)
{
    // Check params
    if ( m_mlc_filename == "" )
    {
        GGcerr << "No mesh file specified for MLC of the LINAC phantom!" << GGendl;
        exit_simulation();
    }

    if ( mh_linac->A_nb_leaves == 0 && mh_linac->B_nb_leaves == 0 )
    {
        GGcerr << "MeshPhanLINACNav: number of leaves per bank must be specified!" << GGendl;
        exit_simulation();
    }

    if ( m_materials_filename == "" || m_linac_material[ 0 ] == "" )
    {
        GGcerr << "MeshPhanLINACNav: navigation required but material information was not provided!" << GGendl;
        exit_simulation();
    }

    // Params
    mh_params = h_params;
    md_params = d_params;

    // Init MLC
    m_init_mlc();    

    // If jaw x is defined, init
    if ( m_jaw_x_filename != "" )
    {
        m_init_jaw_x();

        // place the jaw relatively to the mlc (local frame)
        m_translate_jaw_x( 0, m_loc_pos_jaw_x );
        m_translate_jaw_x( 1, m_loc_pos_jaw_x );        
    }

    // If jaw y is defined, init
    if ( m_jaw_y_filename != "" )
    {
        m_init_jaw_y();

        // place the jaw relatively to the mlc (local frame)
        m_translate_jaw_y( 0, m_loc_pos_jaw_y );
        m_translate_jaw_y( 1, m_loc_pos_jaw_y );
    }

    // Get scale ratio between MLC frame and isocenter, if not defined
    if ( m_sid == 0.0 )
    {
        GGcerr << "MeshPanLINACNav: source to isocenter distance must be defined!" << GGendl;
        exit_simulation();
    }    
    f32 mlc_dist = fxyz_mag( m_pos_mlc );
    if ( mh_linac->mlc_motion_ratio == -1 )
    {
        mh_linac->mlc_motion_ratio = (m_sid - mlc_dist) / m_sid;
    }

    // Get the other scale ratio if not defined
    if ( m_jaw_x_filename != "" && mh_linac->xjaw_motion_ratio == -1 )
    {
        mh_linac->xjaw_motion_ratio = ( m_sid - mlc_dist - fxyz_mag(m_loc_pos_jaw_x) ) / m_sid;
    }
    if ( m_jaw_y_filename != "" && mh_linac->yjaw_motion_ratio == -1 )
    {
        mh_linac->yjaw_motion_ratio = ( m_sid - mlc_dist - fxyz_mag(m_loc_pos_jaw_y) ) / m_sid;
    }

    // Configure the linac
    m_configure_linac();

    // Copy the linac to the GPU
    m_copy_linac_to_gpu();

    // Init materials
    m_materials.load_materials_database( m_materials_filename );
    m_materials.initialize( m_linac_material, h_params );

    // Cross Sections
    m_cross_sections.initialize( m_materials.h_materials, h_params );

    // Some verbose if required
    if ( h_params->display_memory_usage )
    {
        ui64 mem = m_get_memory_usage();
        GGcout_mem( "MeshPhanLINACNav", mem );
    }

}




#endif
