// GGEMS Copyright (C) 2015

/*!
 * \file ct_detector.cuh
 * \brief
 * \author J. Bert <bert.jul@gmail.com>
 * \version 0.1
 * \date 2 december 2015
 *
 *
 *
 */

#ifndef CT_DETECTOR_CUH
#define CT_DETECTOR_CUH

#include "global.cuh"
#include "raytracing.cuh"
#include "particles.cuh"
#include "obb.cuh"

class GGEMSDetector;

class CTDetector : public GGEMSDetector
{
    public:
        CTDetector();
        ~CTDetector() {;};

        // Setting
        void set_width( f32 w );
        void set_height( f32 h );

        void set_pixel_size( f32 sx, f32 sy, f32 sz );
        void set_orbiting_radius( f32 r );

        // Tracking from outside to the detector
        void track_to_in( Particles particles ){}
        void track_to_out( Particles particles ){}

        // Init
        void initialize( GlobalSimulationParameters params ){}

        void digitizer(){}
        void save_data( std::string filename ){}

    private:
        bool m_check_mandatory(){}
        void m_copy_detector_cpu2gpu(){}

        Obb m_phantom;
        f32 m_pixel_size_x, m_pixel_size_y, m_pixel_size_z;
        ui16 m_nb_pixel_x, m_nb_pixel_y;
        f32 m_orbiting_radius;
        f32 *m_projection_h;  // CPU
        f32 *m_projection_d;  // GPU

        GlobalSimulationParameters m_params;

};

#endif

