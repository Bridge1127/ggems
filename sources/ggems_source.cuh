// GGEMS Copyright (C) 2017

/*!
 * \file ggems_source.cuh
 * \brief Header of the abstract source class
 * \author J. Bert <bert.jul@gmail.com>
 * \version 0.2
 * \date 13 novembre 2015
 *
 * Abstract class that handle every sources used in GGEMS
 *
 * v0.2: JB - Change all structs and remove CPU exec
 *
 */

#ifndef GGEMS_SOURCE_CUH
#define GGEMS_SOURCE_CUH

#include "global.cuh"
#include "particles.cuh"

class GGEMSSource {
    public:
        GGEMSSource();
        virtual ~GGEMSSource() {}
        virtual void get_primaries_generator(ParticlesData *d_particles) = 0;
        virtual void initialize(GlobalSimulationParametersData *h_params) = 0;

        std::string get_name();

    protected:
      void set_name(std::string name);

    private:
        std::string m_source_name;

};

#endif
